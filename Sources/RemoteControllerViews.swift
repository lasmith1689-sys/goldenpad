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

#if os(tvOS)
/// Apple TV: who is playing on phones, and how to join.
struct RemoteControllerTVOverlay: View {
    @ObservedObject var host: RemoteControllerHost
    let hasGamepad: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = host.notice {
                label(notice, systemImage: "iphone.gen3")
            }
            if let problem = host.problem {
                label(problem, systemImage: "exclamationmark.triangle")
            } else if host.players.isEmpty && !hasGamepad {
                label("Open GoldenPad on your iPhone to use it as a controller. Up to four can play.",
                      systemImage: "iphone.gen3.radiowaves.left.and.right")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(60)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: host.notice)
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

/// iPhone as a controller: the usual touch controls, sent to the Apple TV.
struct RemoteControllerPadView: View {
    @ObservedObject var client: RemoteControllerClient
    @ObservedObject var input: RecompPrototypeInput
    let placements: [RecompTouchPlacement]
    let deviceClass: RecompTouchDeviceClass
    @Binding var mode: PhoneLaunchMode

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            Image(systemName: "appletv")
                .font(.system(size: 80))
                .foregroundStyle(.white.opacity(0.08))
            RecompPrototypeTouchControls(input: input, placements: placements, deviceClass: deviceClass)
                .ignoresSafeArea()
            HStack(spacing: 12) {
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(.white)
                if case .lost = client.phase {
                    Button("Reconnect") { client.reconnect() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Leave") {
                    input.releaseTouchInput()
                    client.disconnect()
                    mode = .choosing
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(.top, 8)
        }
        .onChange(of: client.phase) { _, _ in input.releaseTouchInput() }
    }

    private var statusText: String {
        let name = client.tv?.name ?? "Apple TV"
        switch client.phase {
        case .idle, .connecting:
            return "Connecting to \(name)…"
        case .connected:
            if let player = client.player { return "Player \(player + 1) · \(name)" }
            return "Waiting for a free player on \(name)"
        case .lost:
            return "Lost connection to \(name)"
        }
    }
}
#endif
