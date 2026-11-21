import SwiftUI

/// How this launch of the iPhone app is used.
enum PhoneLaunchMode: Equatable {
    /// Looking for an Apple TV before starting the game here.
    case choosing
    /// This phone is a controller for an Apple TV; the game does not run here.
    case controller
    /// The game runs on this phone.
    case game

    static var initial: PhoneLaunchMode {
        #if os(tvOS)
        return .game
        #else
        // Test and probe launches (any --flag) go straight to the game.
        let flags = ProcessInfo.processInfo.arguments.dropFirst().contains { $0.hasPrefix("--") }
        return flags ? .game : .choosing
        #endif
    }
}

/// One colour per player, the same on the TV and on each phone, so everyone
/// can see at a glance which player they are.
enum RemotePlayerColor {
    static func color(_ port: Int) -> Color {
        switch port {
        case 0: Color(red: 0.86, green: 0.24, blue: 0.22)
        case 1: Color(red: 0.22, green: 0.47, blue: 0.90)
        case 2: Color(red: 0.24, green: 0.68, blue: 0.33)
        default: Color(red: 0.93, green: 0.72, blue: 0.16)
        }
    }
}

/// A round "1"-"4" badge in the player's colour.
struct RemotePlayerBadge: View {
    let port: Int?
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(port.map(RemotePlayerColor.color) ?? Color.gray.opacity(0.5))
            Text(port.map { "\($0 + 1)" } ?? "–")
                .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

#if os(tvOS)
/// Apple TV: who is playing as which player, how to join, and how to start
/// multiplayer. The players panel shows in GoldenEye's menus and hides
/// during play; short notices (someone joined, left or swapped) always show.
struct RemoteControllerTVOverlay: View {
    @ObservedObject var host: RemoteControllerHost
    /// Someone is moving around a level (hide the panel).
    let inGameplay: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !inGameplay {
                playersPanel
            }
            Spacer(minLength: 0)
            if let notice = host.notice {
                label(notice, systemImage: "gamecontroller")
            }
            if let problem = host.problem {
                label(problem, systemImage: "exclamationmark.triangle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(60)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: host.notice)
        .animation(.easeInOut(duration: 0.25), value: host.seats)
        .animation(.easeInOut(duration: 0.25), value: inGameplay)
    }

    private var playersPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ForEach(0..<RemoteControllerWire.maxPlayers, id: \.self) { port in
                    seatCard(port)
                }
            }
            Text(hint)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(20)
        .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var hint: String {
        if host.startingMultiplayer { return "Taking the game to multiplayer setup…" }
        if host.seats.isEmpty {
            return "Join: open GoldenPad on an iPhone, or pair a game controller with this Apple TV. Up to four players."
        }
        if host.seats.count == 1 {
            return "Add a second player for multiplayer: another iPhone, or a controller paired with this Apple TV."
        }
        var text = "Multiplayer: tap Start Multiplayer on any iPhone, or pick a file, then Multiplayer. Change player on an iPhone to swap."
        if host.waitingCount > 0 { text += " \(host.waitingCount) waiting for a free player." }
        return text
    }

    private func seatCard(_ port: Int) -> some View {
        let seat = host.seats.first { $0.port == port }
        return HStack(spacing: 10) {
            RemotePlayerBadge(port: port, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Player \(port + 1)")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(seat.map { describe($0.device) } ?? "Open")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(seat == nil ? 0.5 : 0.85))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let seat {
                Image(systemName: icon(seat.device))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(seat == nil ? Color.white.opacity(0.06) : RemotePlayerColor.color(port).opacity(0.28)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(seat == nil ? Color.white.opacity(0.15) : RemotePlayerColor.color(port), lineWidth: 2))
    }

    private func describe(_ device: RemoteSeat.Device) -> String {
        switch device {
        case .phoneTouch: "iPhone"
        case .phoneGamepad: "iPhone + controller"
        case .tvGamepad(let name): name
        }
    }

    private func icon(_ device: RemoteSeat.Device) -> String {
        switch device {
        case .phoneTouch: "iphone.gen3"
        case .phoneGamepad, .tvGamepad: "gamecontroller.fill"
        }
    }

    private func label(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.black.opacity(0.72), in: Capsule())
    }
}
#else
/// iPhone: on launch, offer to be a controller for a nearby Apple TV.
struct RemoteControllerLaunchView: View {
    @ObservedObject var client: RemoteControllerClient
    @Binding var mode: PhoneLaunchMode
    /// The last launch was as a controller: keep looking instead of
    /// starting the game after a moment.
    let preferController: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeSearchTime: Double = 0

    private static let autoStartAfter: Double = 2.5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Text("GoldenPad")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.30))
                if client.tvs.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Looking for an Apple TV running GoldenPad…")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else {
                    ForEach(client.tvs) { tv in
                        Button {
                            client.connect(tv)
                            mode = .controller
                        } label: {
                            Label("Be a controller for \(tv.name)", systemImage: "appletv")
                                .frame(maxWidth: 360)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.72, green: 0.56, blue: 0.18))
                        .controlSize(.large)
                    }
                }
                Button("Play on this iPhone") {
                    client.stopBrowsing()
                    mode = .game
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .controlSize(.large)
            }
            .padding(24)
        }
        .onAppear { client.startBrowsing() }
        .task {
            // Count only time the app is in front: the first launch shows
            // the Local Network permission prompt, which must not use up
            // the wait.
            while !Task.isCancelled && mode == .choosing {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if scenePhase == .active { activeSearchTime += 0.25 }
                if !preferController && client.tvs.isEmpty && activeSearchTime >= Self.autoStartAfter {
                    client.stopBrowsing()
                    mode = .game
                }
            }
        }
    }
}

/// iPhone as a controller for an Apple TV. Three ways to play:
/// - a gamepad held in or paired with the phone (the touch controls hide);
/// - in GoldenEye's menus, a simple menu pad: stick, Select, Back, Start;
/// - in a level, GoldenPad's usual touch controls.
/// The player badge, player picker and Start Multiplayer sit in a bar that,
/// like every control here, stays clear of the Dynamic Island and corners.
struct RemoteControllerPadView: View {
    @ObservedObject var client: RemoteControllerClient
    @ObservedObject var input: RecompPrototypeInput
    let placements: [RecompTouchPlacement]
    let deviceClass: RecompTouchDeviceClass
    @Binding var mode: PhoneLaunchMode

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let port = client.player {
                RemotePlayerColor.color(port).opacity(0.10).ignoresSafeArea()
            }
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                controls
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: client.phase) { _, _ in input.releaseTouchInput() }
        .onChange(of: client.gameplay) { _, _ in input.releaseTouchInput() }
    }

    @ViewBuilder
    private var controls: some View {
        if let name = input.externalControllerName {
            gamepadCard(name)
        } else if client.gameplay {
            RecompPrototypeTouchControls(input: input, placements: placements, deviceClass: deviceClass)
        } else {
            RemoteMenuPad(input: input)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            RemotePlayerBadge(port: client.player, size: 34)
            Text(statusText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            if case .lost = client.phase {
                Button("Reconnect") { client.reconnect() }
                    .buttonStyle(.borderedProminent)
            }
            if client.isConnected {
                if !client.gameplay && client.playerCount >= 2 {
                    Button {
                        client.requestMultiplayer()
                    } label: {
                        Label(client.startingMultiplayer ? "Starting…" : "Start Multiplayer",
                              systemImage: "person.3.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.72, green: 0.56, blue: 0.18))
                    .disabled(client.startingMultiplayer)
                }
                Menu {
                    ForEach(0..<RemoteControllerWire.maxPlayers, id: \.self) { port in
                        Button {
                            client.requestPlayer(port)
                        } label: {
                            if port == client.player {
                                Label("Player \(port + 1)", systemImage: "checkmark")
                            } else {
                                Text("Player \(port + 1)")
                            }
                        }
                    }
                } label: {
                    Label("Player", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            Button("Leave") {
                input.releaseTouchInput()
                client.disconnect()
                mode = .choosing
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private func gamepadCard(_ name: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 56))
                .foregroundStyle(client.player.map(RemotePlayerColor.color) ?? .white)
            Text("Playing with \(name)")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text(client.player.map { "It is Player \($0 + 1) on \(client.tv?.name ?? "the Apple TV"). Its buttons work like on the TV: triggers fire and aim, the right stick looks." }
                 ?? "Waiting for a free player on the Apple TV.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: 520)
            Text("Detach the controller to use the touch controls instead.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(24)
    }

    private var statusText: String {
        let name = client.tv?.name ?? "Apple TV"
        switch client.phase {
        case .idle, .connecting:
            return "Connecting to \(name)…"
        case .connected:
            if let player = client.player {
                return "Player \(player + 1) · \(name)" + (client.gameplay ? "" : " · menus")
            }
            return "Waiting for a free player on \(name)"
        case .lost:
            return "Lost connection to \(name)"
        }
    }
}

/// GoldenEye's menus need only a stick, Select (A), Back (B) and Start, so
/// the phone shows just those, large, instead of the full shooter layout.
struct RemoteMenuPad: View {
    @ObservedObject var input: RecompPrototypeInput

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.height * 0.82, geometry.size.width * 0.42)
            HStack(spacing: 0) {
                RecompStick(title: "MOVE", symbol: "arrow.up.and.down.and.arrow.left.and.right") {
                    input.setMovement($0)
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        menuButton("BACK", RecompN64Button.b, Color(red: 0.25, green: 0.55, blue: 0.30), size: side * 0.34)
                        menuButton("SELECT", RecompN64Button.a, Color(red: 0.22, green: 0.42, blue: 0.85), size: side * 0.42)
                    }
                    menuButton("START", RecompN64Button.start, Color(red: 0.70, green: 0.18, blue: 0.18), size: side * 0.26)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func menuButton(_ title: String, _ mask: UInt16, _ tint: Color, size: CGFloat) -> some View {
        RecompMomentaryButton(title: title, tint: tint) { pressed in
            input.setButton(mask, pressed: pressed)
        }
        .frame(width: size, height: size)
    }
}
#endif
