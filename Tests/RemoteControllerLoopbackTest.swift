import Foundation
import Network

// End-to-end check of "use your iPhone as a controller" on one Mac: a TV
// server advertises over Bonjour, two phones find it by browsing, connect,
// send scripted input, and the TV's mixer must see each phone as its own
// player. The TV sends status back (player number, rumble) and notices when
// a phone leaves. Same transport code as the apps, real sockets, no mocks.

private func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

private func waitFor(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
    if !poll(timeout, condition) { fail("timed out waiting for \(what)") }
    print("ok: \(what)")
}

private func poll(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return true
}

/// Shared state, touched only under the lock.
private final class Box<T> {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func read<R>(_ body: (T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(value) }
    func write(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
}

@main
struct RemoteControllerLoopbackTest {
    static func main() {
        let serviceName = "GoldenPad CI \(UUID().uuidString.prefix(8))"
        let mixer = Box(RemotePlayerMixer())
        let received = Box([Int: [RemoteControllerInput]]())
        let disconnects = Box(0)

        // ---------- TV
        let server = RemoteControllerServer()
        let serverPort = Box<UInt16?>(nil)
        server.onReady = { port in serverPort.write { $0 = port } }
        server.onFailed = { fail("TV listener failed: \($0)") }
        server.onConnect = { id in
            var player: Int?
            mixer.write { player = $0.connect(id) }
            server.send(RemoteControllerStatus(player: player, rumble: false), to: id)
        }
        server.onInput = { id, input in
            mixer.write { m in
                m.receive(input, from: id, now: ProcessInfo.processInfo.systemUptime)
                if let port = m.port(of: id) {
                    received.write { $0[port, default: []].append(input) }
                }
            }
            // Rumble player 2's phone once it presses fire.
            if input.buttons & 0x2000 != 0, mixer.read({ $0.port(of: id) }) == 1 {
                server.send(RemoteControllerStatus(player: 1, rumble: true), to: id)
            }
        }
        server.onDisconnect = { id in
            mixer.write { _ = $0.disconnect(id) }
            disconnects.write { $0 += 1 }
        }
        do {
            try server.start(name: serviceName)
        } catch {
            fail("TV listener did not start: \(error)")
        }
        waitFor("TV is listening") { serverPort.read { $0 != nil } }

        // ---------- phones find the TV over Bonjour
        let browser = RemoteControllerBrowser()
        let found = Box<RemoteControllerTV?>(nil)
        browser.onChange = { tvs in
            if let tv = tvs.first(where: { $0.name == serviceName }) { found.write { $0 = tv } }
        }
        browser.start()
        let bonjourFound = poll(20) { found.read { $0 != nil } }
        browser.stop()
        let tv: RemoteControllerTV
        if bonjourFound, let discovered = found.read({ $0 }) {
            print("ok: phone finds the TV by Bonjour (\(discovered.endpoint))")
            tv = discovered
        } else if ProcessInfo.processInfo.environment["REQUIRE_BONJOUR"] == "1" {
            fail("phone did not find the TV by Bonjour")
        } else {
            // Some CI machines block multicast DNS; still test everything else.
            print("WARN: Bonjour discovery unavailable here; connecting to the TV's port directly")
            let port = NWEndpoint.Port(rawValue: serverPort.read { $0 } ?? 0)!
            tv = RemoteControllerTV(name: serviceName, endpoint: .hostPort(host: "127.0.0.1", port: port))
        }

        func makePhone(_ label: String) -> (RemoteControllerLink, Box<[RemoteControllerStatus]>, Box<RemoteControllerLink.State?>) {
            let link = RemoteControllerLink(endpoint: tv.endpoint)
            let statuses = Box([RemoteControllerStatus]())
            let state = Box<RemoteControllerLink.State?>(nil)
            link.onStatus = { status in statuses.write { $0.append(status) } }
            link.onState = { next in state.write { $0 = next } }
            link.start()
            waitFor("\(label) connects") { state.read { $0 == .ready } }
            return (link, statuses, state)
        }

        let (phoneA, statusA, _) = makePhone("phone A")
        waitFor("phone A is told it is player 1") { statusA.read { $0.first?.player == 0 } }
        let (phoneB, statusB, stateB) = makePhone("phone B")
        waitFor("phone B is told it is player 2") { statusB.read { $0.first?.player == 1 } }

        // ---------- scripted input
        var walk = RemoteControllerInput()
        walk.stick = SIMD2(0, 1)
        walk.look = SIMD2(0.05, 0)
        for _ in 0..<10 { phoneA.send(walk) }
        var fire = RemoteControllerInput()
        fire.buttons = 0x2000 // Z: fire
        fire.crouchPresses = 0
        phoneB.send(fire)
        fire.crouchPresses = 2 // two crouch presses
        phoneB.send(fire)

        waitFor("TV got phone A's ten frames as player 1") { received.read { $0[0]?.count ?? 0 } >= 10 }
        waitFor("TV got phone B's fire as player 2") { received.read { $0[1]?.count ?? 0 } >= 2 }
        let frames = mixer.write2 { $0.drain(now: ProcessInfo.processInfo.systemUptime) }
        guard let p1 = frames.first(where: { $0.port == 0 }),
              let p2 = frames.first(where: { $0.port == 1 }) else { fail("missing player frames: \(frames)") }
        if abs(p1.stick.y - 1) > 0.001 || abs(p1.look.x - 0.5) > 0.01 || p1.buttons != 0 {
            fail("player 1 frame wrong: \(p1)")
        }
        if p2.buttons != 0x2000 || p2.crouchPresses != 2 || p2.stick != .zero {
            fail("player 2 frame wrong: \(p2)")
        }
        print("ok: player 1 walks and turns, player 2 fires and crouched twice, no cross-talk")
        waitFor("phone B feels rumble") { statusB.read { $0.contains { $0.rumble && $0.player == 1 } } }

        // ---------- leaving
        phoneB.cancel()
        waitFor("phone B's link ends") { stateB.read { if case .ended = $0 { return true }; return false } }
        waitFor("TV notices phone B left") { disconnects.read { $0 } >= 1 }
        if mixer.read({ $0.portMask }) != 0b1 { fail("player 2 still held after phone B left") }
        print("ok: player 2 is free again")

        phoneA.cancel()
        waitFor("TV notices phone A left") { disconnects.read { $0 } >= 2 }
        server.stop()
        print("PASS: phones found the TV, joined as players 1 and 2, sent input, got rumble, and left cleanly")
        exit(0)
    }
}

private extension Box {
    func write2<R>(_ body: (inout T) -> R) -> R {
        var result: R?
        write { result = body(&$0) }
        return result!
    }
}
