import Foundation
import Network

// A scripted "iPhone" for CI: finds the Apple TV app (running in the
// simulator on the same Mac) over Bonjour, joins it, checks which player it
// was given, then presses Start a few times like a person at the title
// screen. Prints what happened; exits non-zero if it could not play.

private func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

private func poll(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return true
}

private final class Box<T> {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func read<R>(_ body: (T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(value) }
    func write(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
}

@main
struct RemoteControllerPhoneScript {
    static func main() {
        let found = Box<RemoteControllerTV?>(nil)
        let browser = RemoteControllerBrowser()
        browser.onChange = { tvs in if let tv = tvs.first { found.write { $0 = tv } } }
        browser.start()
        guard poll(60, { found.read { $0 != nil } }), let tv = found.read({ $0 }) else {
            fail("no Apple TV running GoldenPad was found over Bonjour")
        }
        browser.stop()
        print("ok: found \"\(tv.name)\"")

        let statuses = Box([RemoteControllerStatus]())
        let state = Box<RemoteControllerLink.State?>(nil)
        let link = RemoteControllerLink(endpoint: tv.endpoint)
        link.onStatus = { status in statuses.write { $0.append(status) } }
        link.onState = { next in state.write { $0 = next } }
        link.start()
        guard poll(15, { state.read { $0 == .ready } }) else { fail("could not connect: \(String(describing: state.read { $0 }))") }
        guard poll(10, { statuses.read { !$0.isEmpty } }) else { fail("the TV never said which player this phone is") }
        let player = statuses.read { $0.last?.player }
        guard let player else { fail("the TV had no free player") }
        print("ok: joined as Player \(player + 1)")

        if ProcessInfo.processInfo.environment["PHONE_SCRIPT"] == "solo-walk" {
            soloWalk(link: link, statuses: statuses, state: state, player: player)
        }

        // ~60 frames a second, like the app: press Start for 0.1 s every 2 s.
        let seconds = Double(ProcessInfo.processInfo.environment["PHONE_SECONDS"] ?? "") ?? 20
        let frames = Int(seconds * 60)
        var presses = 0
        for frame in 0..<frames {
            var input = RemoteControllerInput()
            if frame % 120 >= 60 && frame % 120 < 66 {
                input.buttons = 0x1000 // Start
                if frame % 120 == 60 { presses += 1 }
            }
            link.send(input)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60.0))
            if case .ended(let reason) = state.read({ $0 }) {
                fail("the TV dropped the connection after \(frame) frames: \(reason ?? "closed")")
            }
        }
        print("ok: sent \(frames) frames with \(presses) Start presses; connection still up")
        print("statuses from TV: \(statuses.read { $0.count }) (rumble seen: \(statuses.read { $0.contains { $0.rumble } }))")
        link.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        print("PASS: phone script played as Player \(player + 1)")
        exit(0)
    }
}

/// PHONE_SCRIPT=solo-walk (game running on the TV, this phone Player 1):
/// press Start through GoldenEye's front end until the TV reports gameplay,
/// then walk forward, sidestep and turn, printing each phase so the TV's own
/// log can be lined up against it.
private func soloWalk(
    link: RemoteControllerLink,
    statuses: Box<[RemoteControllerStatus]>,
    state: Box<RemoteControllerLink.State?>,
    player: Int
) -> Never {
    func inGameplay() -> Bool { statuses.read { $0.last?.gameplay ?? false } }
    func send(_ input: RemoteControllerInput, frames: Int) {
        for _ in 0..<frames {
            link.send(input)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60.0))
            if case .ended(let reason) = state.read({ $0 }) {
                fail("the TV dropped the connection: \(reason ?? "closed")")
            }
        }
    }
    let timeout = Double(ProcessInfo.processInfo.environment["PHONE_GAMEPLAY_TIMEOUT"] ?? "") ?? 150
    let started = Date()
    var presses = 0
    var start = RemoteControllerInput()
    start.buttons = 0x1000
    while !inGameplay() {
        if Date().timeIntervalSince(started) > timeout {
            fail("no gameplay after \(presses) Start presses in \(Int(timeout)) s")
        }
        send(start, frames: 6)
        presses += 1
        print("phase: start press \(presses) at \(Int(Date().timeIntervalSince(started))) s")
        send(RemoteControllerInput(), frames: 84)
    }
    print("ok: gameplay after \(presses) Start presses (\(Int(Date().timeIntervalSince(started))) s)")
    send(RemoteControllerInput(), frames: 120)
    var walk = RemoteControllerInput()
    walk.stick = SIMD2(0, 1)
    print("phase: walk forward 3 s")
    send(walk, frames: 180)
    send(RemoteControllerInput(), frames: 60)
    walk.stick = SIMD2(1, 0)
    print("phase: sidestep right 2 s")
    send(walk, frames: 120)
    send(RemoteControllerInput(), frames: 60)
    var turn = RemoteControllerInput()
    turn.look = SIMD2(0.3, 0)
    print("phase: turn right 1 s")
    send(turn, frames: 60)
    send(RemoteControllerInput(), frames: 120)
    print("phase: done; still in gameplay: \(inGameplay())")
    link.cancel()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    print("PASS: phone walked as Player \(player + 1)")
    exit(0)
}
