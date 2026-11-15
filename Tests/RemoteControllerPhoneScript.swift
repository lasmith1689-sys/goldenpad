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
