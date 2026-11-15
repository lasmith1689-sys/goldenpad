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

/// Apple TV side of "use your iPhone as a controller": listens for phones,
/// seats each as player 1-4 and hands the input model one frame per player
/// per tick. A game controller paired with the TV keeps player 1.
@MainActor
final class RemoteControllerHost: ObservableObject {
    /// Players held by phones, 0-based, sorted.
    @Published private(set) var players: [Int] = []
    @Published private(set) var waitingCount = 0
    /// Short notice for the TV screen, such as "iPhone joined as Player 2".
    @Published private(set) var notice: String?
    @Published private(set) var problem: String?

    private let core = RemoteControllerHostCore()
    private var started = false
    private var loggedButtons: [Int: UInt16] = [:]
    private var noticeTask: Task<Void, Never>?

    func start() {
        guard !started else { return }
        started = true
        let core = core
        core.server.onConnect = { [weak self] id in
            let player = core.withMixer { $0.connect(id) }
            core.sendStatus(RemoteControllerStatus(player: player, rumble: false), to: id)
            Task { @MainActor in
                self?.refreshPlayers()
                self?.show(player.map { "iPhone joined as Player \($0 + 1)" }
                    ?? "An iPhone is waiting: all four players are taken")
            }
        }
        core.server.onInput = { id, input in
            let now = ProcessInfo.processInfo.systemUptime
            core.withMixer { $0.receive(input, from: id, now: now) }
        }
        core.server.onDisconnect = { [weak self] id in
            let (port, seated) = core.withMixer { mixer -> (Int?, [(UUID, Int?)]) in
                let port = mixer.port(of: id)
                let seated = mixer.disconnect(id)
                return (port, seated.map { ($0, mixer.port(of: $0)) })
            }
            core.forget(id)
            for (phone, player) in seated {
                core.sendStatus(RemoteControllerStatus(player: player, rumble: false), to: phone)
            }
            Task { @MainActor in
                self?.refreshPlayers()
                if let port { self?.show("Player \(port + 1)'s iPhone left") }
            }
        }
        core.server.onFailed = { [weak self] message in
            Task { @MainActor in self?.problem = "iPhones can't connect: \(message)" }
        }
        core.server.onReady = { port in
            NSLog("[GoldenPad] remote: listening for iPhones on port %d", Int(port))
        }
        do {
            try core.server.start()
        } catch {
            problem = "iPhones can't connect: \(error.localizedDescription)"
        }
    }

    /// Called every tick by the input model on the main thread. Returns each
    /// seated phone's input, and sends any player or rumble changes back.
    func tick(reservedPort: Int?, rumble: (Int) -> Bool) -> [RemotePlayerFrame] {
        let now = ProcessInfo.processInfo.systemUptime
        let (moved, frames, owners) = core.withMixer { mixer in
            (mixer.setReservedPort(reservedPort), mixer.drain(now: now), mixer.slots.owners)
        }
        if !moved.isEmpty { refreshPlayers() }
        for frame in frames where loggedButtons[frame.port] != frame.buttons {
            // (a few lines per press; the CI simulator test reads these)
            loggedButtons[frame.port] = frame.buttons
            NSLog("[GoldenPad] remote: player %d buttons 0x%04x", frame.port + 1, frame.buttons)
        }
        guard started, !owners.isEmpty || !moved.isEmpty else { return frames }
        let statuses = owners.map { port, id in
            (id, RemoteControllerStatus(player: port, rumble: rumble(port)))
        }
        let unseated = moved.filter { !owners.values.contains($0) }
        let core = core
        core.server.queue.async {
            for (id, status) in statuses { core.sendStatus(status, to: id) }
            for id in unseated {
                core.sendStatus(RemoteControllerStatus(player: nil, rumble: false), to: id)
            }
        }
        return frames
    }

    private func refreshPlayers() {
        let (ports, waiting) = core.withMixer { ($0.slots.occupiedPorts, $0.connectedCount - $0.slots.occupiedPorts.count) }
        if ports != players { players = ports }
        if waiting != waitingCount { waitingCount = waiting }
    }

    private func show(_ message: String) {
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
    @Published private(set) var browseProblem: String?

    private var browser: RemoteControllerBrowser?
    private var link: RemoteControllerLink?
    private var hapticTick = 0
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
        link?.cancel()
        self.tv = tv
        player = nil
        rumble = false
        let link = RemoteControllerLink(endpoint: tv.endpoint)
        link.onState = { [weak self, weak link] state in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                switch state {
                case .connecting: self.phase = .connecting
                case .ready: self.phase = .connected
                case .ended(let reason):
                    self.phase = .lost(reason ?? "The Apple TV closed the connection.")
                    self.rumble = false
                }
            }
        }
        link.onStatus = { [weak self] status in
            Task { @MainActor in
                self?.player = status.player
                self?.rumble = status.rumble
            }
        }
        self.link = link
        link.start()
    }

    func reconnect() {
        if let tv { connect(tv) }
    }

    func disconnect() {
        link?.cancel()
        link = nil
        tv = nil
        player = nil
        rumble = false
        phase = .idle
    }

    /// Called by the input model every tick while connected.
    func send(_ input: RemoteControllerInput) {
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
