import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The TV host's network-side state: touched from the server's queue and,
/// under the lock, from the main thread's tick.
private final class RemoteControllerHostCore: @unchecked Sendable {
    let server = RemoteControllerServer()
    private let lock = NSLock()
    private var mixer = RemotePlayerMixer()               // under lock
    private var sent: [UUID: RemoteControllerStatus] = [:] // server queue only

    func withMixer<R>(_ body: (inout RemotePlayerMixer) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&mixer)
    }

    /// On the server queue. Sends only changes.
    func sendStatus(_ status: RemoteControllerStatus, to id: UUID) {
        guard sent[id] != status else { return }
        sent[id] = status
        server.send(status, to: id)
    }

    func forget(_ id: UUID) { sent[id] = nil }
}

/// One player on the TV, for the players panel.
struct RemoteSeat: Equatable, Identifiable {
    enum Device: Equatable {
        /// A phone using its touch controls.
        case phoneTouch
        /// A phone forwarding a gamepad held in or paired with it.
        case phoneGamepad
        /// A gamepad paired with the Apple TV itself.
        case tvGamepad(String)
    }
    let port: Int
    let device: Device
    var id: Int { port }
}

/// Apple TV side of "use your iPhone as a controller": listens for phones,
/// seats phones and the TV's own gamepads as players 1-4 in the order they
/// arrive, lets any of them swap players, and hands the input model one
/// frame per player per tick.
@MainActor
final class RemoteControllerHost: ObservableObject {
    /// Who holds each player, sorted by player.
    @Published private(set) var seats: [RemoteSeat] = []
    @Published private(set) var waitingCount = 0
    /// Short notice for the TV screen, such as "iPhone joined as Player 2".
    @Published private(set) var notice: String?
    @Published private(set) var problem: String?
    /// Set while the TV drives GoldenEye's menus to the multiplayer screen.
    @Published var startingMultiplayer = false

    private let core = RemoteControllerHostCore()
    private var started = false
    private var loggedButtons: [Int: UInt16] = [:]
    private var localGamepads: [UUID: String] = [:]
    private var noticeTask: Task<Void, Never>?

    func start() {
        guard !started else { return }
        started = true
        let core = core
        core.server.onConnect = { [weak self] id in
            let player = core.withMixer { $0.connect(id) }
            core.sendStatus(RemoteControllerStatus(player: player, rumble: false), to: id)
            Task { @MainActor in
                self?.refreshSeats()
                self?.show(player.map { "iPhone joined as Player \($0 + 1)" }
                    ?? "An iPhone is waiting: all four players are taken")
            }
        }
        core.server.onInput = { [weak self] id, input in
            let now = ProcessInfo.processInfo.systemUptime
            let changed = core.withMixer { $0.receive(input, from: id, now: now) }
            guard !changed.isEmpty else { return }
            let port = core.withMixer { $0.port(of: id) }
            Task { @MainActor in
                self?.refreshSeats()
                if let port { self?.show("An iPhone moved to Player \(port + 1)") }
            }
        }
        core.server.onDisconnect = { [weak self] id in
            let port = core.withMixer { mixer -> Int? in
                let port = mixer.port(of: id)
                mixer.disconnect(id)
                return port
            }
            core.forget(id)
            Task { @MainActor in
                self?.refreshSeats()
                if let port { self?.show("Player \(port + 1)'s iPhone left") }
            }
        }
        core.server.onFailed = { [weak self] message in
            NSLog("[GoldenPad] remote: listener stopped (%@); restarting", message)
            Task { @MainActor in self?.problem = "iPhones can't connect right now: \(message). Retrying…" }
            core.server.queue.asyncAfter(deadline: .now() + 2) { core.server.restartIfNeeded() }
        }
        core.server.onReady = { [weak self] port in
            NSLog("[GoldenPad] remote: listening for iPhones on port %d", Int(port))
            Task { @MainActor in self?.problem = nil }
        }
        do {
            try core.server.start()
        } catch {
            problem = "iPhones can't connect: \(error.localizedDescription)"
        }
    }

    /// The app is in front again: tvOS may have stopped the listener while
    /// it was in the background, so start a fresh one (phones that were
    /// connected reconnect by themselves).
    func appBecameActive() {
        guard started else { return }
        core.server.restartIfNeeded(force: true)
    }

    /// The gamepads paired with the TV (id -> name). They join as players in
    /// arrival order, like phones.
    func setLocalGamepads(_ gamepads: [UUID: String]) {
        guard gamepads != localGamepads else { return }
        let joined = gamepads.keys.filter { localGamepads[$0] == nil }
        let left = localGamepads.keys.filter { gamepads[$0] == nil }
        localGamepads = gamepads
        let notices = core.withMixer { mixer -> [String] in
            var notices: [String] = []
            for id in left {
                if let port = mixer.port(of: id) { notices.append("Player \(port + 1)'s controller disconnected") }
                mixer.disconnect(id)
            }
            for id in joined {
                let port = mixer.connect(id, localGamepad: true)
                notices.append(port.map { "\(gamepads[id] ?? "Controller") joined as Player \($0 + 1)" }
                    ?? "A controller is waiting: all four players are taken")
            }
            return notices
        }
        refreshSeats()
        if let last = notices.last { show(last) }
    }

    /// Moves a player to another player number (from the TV's players
    /// panel), swapping with whoever has it.
    func swap(_ port: Int, with other: Int) {
        core.withMixer { mixer in
            if let id = mixer.slots.owners[port] { mixer.seat(id, at: other) }
        }
        refreshSeats()
        show("Player \(port + 1) and Player \(other + 1) swapped places")
    }

    /// The controller holding `port`, if any.
    func holder(of port: Int) -> UUID? {
        core.withMixer { $0.slots.owners[port] }
    }

    /// Closes gaps between players before multiplayer (GoldenEye stops
    /// counting controllers at the first empty port).
    func compactPlayers() {
        let changed = core.withMixer { $0.compact() }
        if !changed.isEmpty { refreshSeats() }
    }

    /// True once after a phone asked to start multiplayer.
    func takeMultiplayerRequest() -> Bool {
        core.withMixer { $0.takeMultiplayerRequest() }
    }

    /// Called every tick by the input model on the main thread with this
    /// tick's input from the TV's own gamepads. Returns every seated
    /// player's input, and sends phones any status change.
    func tick(
        localInput: [UUID: RemoteControllerInput],
        rumble: (Int) -> Bool,
        gameplay: (Int) -> Bool
    ) -> [RemotePlayerFrame] {
        let now = ProcessInfo.processInfo.systemUptime
        let (frames, owners, phones, kinds) = core.withMixer {
            mixer -> ([RemotePlayerFrame], [Int: UUID], Set<UUID>, [UUID: RemoteControllerKind]) in
            for (id, input) in localInput { mixer.receive(input, from: id, now: now) }
            let phones = Set(mixer.slots.owners.values.filter { !mixer.isLocalGamepad($0) })
            var kinds: [UUID: RemoteControllerKind] = [:]
            for id in phones { kinds[id] = mixer.latestKind(of: id) }
            return (mixer.drain(now: now), mixer.slots.owners, phones, kinds)
        }
        for frame in frames where loggedButtons[frame.port] != frame.buttons {
            // (a few lines per press; the CI simulator test reads these)
            loggedButtons[frame.port] = frame.buttons
            NSLog("[GoldenPad] remote: player %d buttons 0x%04x", frame.port + 1, frame.buttons)
        }
        if kinds != phoneKinds {
            phoneKinds = kinds
            refreshSeats()
        }
        guard started else { return frames }
        let count = owners.count
        let multiplayer = startingMultiplayer
        let statuses = owners.compactMap { port, id -> (UUID, RemoteControllerStatus)? in
            guard phones.contains(id) else { return nil }
            return (id, RemoteControllerStatus(
                player: port, rumble: rumble(port), gameplay: gameplay(port),
                startingMultiplayer: multiplayer, playerCount: count))
        }
        let core = core
        core.server.queue.async {
            for (id, status) in statuses { core.sendStatus(status, to: id) }
        }
        return frames
    }

    private var phoneKinds: [UUID: RemoteControllerKind] = [:]

    private func refreshSeats() {
        let names = localGamepads
        let (next, waiting) = core.withMixer { mixer -> ([RemoteSeat], Int) in
            let seats = mixer.slots.owners.sorted { $0.key < $1.key }.map { port, id -> RemoteSeat in
                if mixer.isLocalGamepad(id) {
                    return RemoteSeat(port: port, device: .tvGamepad(names[id] ?? "Controller"))
                }
                return RemoteSeat(port: port, device: mixer.latestKind(of: id) == .gamepad ? .phoneGamepad : .phoneTouch)
            }
            return (seats, mixer.connectedCount - seats.count)
        }
        if next != seats { seats = next }
        if waiting != waitingCount { waitingCount = waiting }
    }

    func show(_ message: String) {
        NSLog("[GoldenPad] remote: %@", message)
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }
}

/// iPhone side: finds Apple TVs running GoldenPad and, once connected,
/// sends the touch controls there instead of to the local game.
@MainActor
final class RemoteControllerClient: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case lost(String)
    }

    @Published private(set) var tvs: [RemoteControllerTV] = []
    @Published private(set) var phase = Phase.idle
    @Published private(set) var tv: RemoteControllerTV?
    /// 0-based player the TV gave this phone; nil while waiting for one.
    @Published private(set) var player: Int?
    @Published private(set) var rumble = false
    /// This phone's player is moving around a level (not in menus).
    @Published private(set) var gameplay = false
    /// Players seated on the TV, counting this phone.
    @Published private(set) var playerCount = 0
    /// The TV is taking the game to the multiplayer screen.
    @Published private(set) var startingMultiplayer = false
    @Published private(set) var browseProblem: String?

    private var browser: RemoteControllerBrowser?
    private var link: RemoteControllerLink?
    private var hapticTick = 0
    private var command = RemoteControllerCommand.none
    private var commandSerial: UInt8 = 0
    /// Tries left to reach the TV again by itself after losing it.
    private var autoRetries = 0
    private var retryTask: Task<Void, Never>?
    #if os(iOS)
    private let haptics = UIImpactFeedbackGenerator(style: .heavy)
    #endif

    var isConnected: Bool { phase == .connected }

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = RemoteControllerBrowser()
        browser.onChange = { [weak self] tvs in
            Task { @MainActor in
                self?.tvs = tvs
                self?.browseProblem = nil
            }
        }
        browser.onFailed = { [weak self] message in
            Task { @MainActor in self?.browseProblem = message }
        }
        self.browser = browser
        browser.start()
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
    }

    func connect(_ tv: RemoteControllerTV) {
        autoRetries = 15
        open(tv)
    }

    private func open(_ tv: RemoteControllerTV) {
        retryTask?.cancel()
        link?.cancel()
        self.tv = tv
        player = nil
        rumble = false
        gameplay = false
        playerCount = 0
        startingMultiplayer = false
        command = RemoteControllerCommand.none
        let link = RemoteControllerLink(endpoint: tv.endpoint)
        link.onState = { [weak self, weak link] state in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                switch state {
                case .connecting:
                    if case .lost = self.phase {} else { self.phase = .connecting }
                case .ready:
                    self.phase = .connected
                    self.autoRetries = 15
                case .ended(let reason):
                    let name = self.tv?.name ?? "the Apple TV"
                    self.phase = .lost(reason == RemoteControllerLink.timedOut
                        ? "Can't reach \(name). Is GoldenPad open on the Apple TV?"
                        : (reason ?? "\(name) closed the connection."))
                    self.rumble = false
                    self.retryLater()
                }
            }
        }
        link.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.player = status.player
                self.rumble = status.rumble
                if self.gameplay != status.gameplay { self.gameplay = status.gameplay }
                if self.playerCount != status.playerCount { self.playerCount = status.playerCount }
                if self.startingMultiplayer != status.startingMultiplayer {
                    self.startingMultiplayer = status.startingMultiplayer
                }
            }
        }
        self.link = link
        link.start()
    }

    func reconnect() {
        if let tv { connect(tv) }
    }

    /// Lost the TV: try again in a few seconds (the TV app may be coming
    /// back to the front). Uses a fresh lookup of the TV each time.
    private func retryLater() {
        guard autoRetries > 0, let tv else { return }
        autoRetries -= 1
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, case .lost = self.phase, self.tv == tv else { return }
            self.open(self.tvs.first { $0.name == tv.name } ?? (self.tvs.count == 1 ? self.tvs[0] : tv))
        }
    }

    func disconnect() {
        retryTask?.cancel()
        autoRetries = 0
        link?.cancel()
        link = nil
        tv = nil
        player = nil
        rumble = false
        phase = .idle
    }

    /// Called by the input model every tick while connected.
    /// Asks the TV to make this phone player `port` (swapping with whoever has it).
    func requestPlayer(_ port: Int) {
        issue(RemoteControllerCommand.becomePlayer(port))
    }

    /// Asks the TV to take GoldenEye's menus to the multiplayer screen.
    func requestMultiplayer() {
        issue(RemoteControllerCommand.startMultiplayer)
    }

    private func issue(_ next: UInt8) {
        command = next
        commandSerial &+= 1
    }

    func send(_ input: RemoteControllerInput) {
        var input = input
        input.command = command
        input.commandSerial = commandSerial
        link?.send(input)
        #if os(iOS)
        // GoldenEye pulses the Rumble Pak motor; buzz about 20 times a second.
        if rumble {
            hapticTick += 1
            if hapticTick % 3 == 0 { haptics.impactOccurred(intensity: 0.8) }
        }
        #endif
    }
}
