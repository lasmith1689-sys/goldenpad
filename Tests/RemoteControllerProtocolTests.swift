import Foundation

private struct ProtocolTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: Bool, _ description: String) throws {
    guard condition else { throw ProtocolTestFailure(description: description) }
}

private func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.0002 }

@main
struct RemoteControllerProtocolTests {
    static func main() throws {
        // Input round trip, including clamping and negative values.
        var input = RemoteControllerInput()
        input.buttons = 0x2000 | 0x0010 | 0x1000
        input.stick = SIMD2(-0.5, 1)
        input.look = SIMD2(0.25, -2) // look.y clamps to -1
        input.crouchPresses = 7
        input.reloadPresses = 255
        let data = input.encoded()
        try expect(data.count == RemoteControllerInput.size, "input frame is \(RemoteControllerInput.size) bytes")
        guard let decoded = RemoteControllerInput(data) else {
            throw ProtocolTestFailure(description: "input frame decodes")
        }
        try expect(decoded.buttons == input.buttons, "buttons survive")
        try expect(near(decoded.stick.x, -0.5) && near(decoded.stick.y, 1), "stick survives")
        try expect(near(decoded.look.x, 0.25) && near(decoded.look.y, -1), "look survives and clamps")
        try expect(decoded.crouchPresses == 7 && decoded.reloadPresses == 255, "press counters survive")

        // Wrong version or size is rejected.
        var wrongVersion = data
        wrongVersion[0] = 99
        try expect(RemoteControllerInput(wrongVersion) == nil, "wrong version rejected")
        try expect(RemoteControllerInput(data.prefix(10)) == nil, "short frame rejected")

        // Status round trip.
        for status in [RemoteControllerStatus(player: 2, rumble: true), RemoteControllerStatus(player: nil, rumble: false), RemoteControllerStatus(player: 0, rumble: false, gameplay: true)] {
            guard let back = RemoteControllerStatus(status.encoded()) else {
                throw ProtocolTestFailure(description: "status frame decodes")
            }
            try expect(back == status, "status survives: \(status)")
        }

        // Gamepad frames and requests survive too.
        var pad = RemoteControllerInput()
        pad.kind = .gamepad
        pad.look = SIMD2(-1, 0.5)
        pad.command = RemoteControllerCommand.becomePlayer(2)
        pad.commandSerial = 9
        guard let padBack = RemoteControllerInput(pad.encoded()) else {
            throw ProtocolTestFailure(description: "gamepad frame decodes")
        }
        try expect(padBack.kind == .gamepad && near(padBack.look.x, -1), "gamepad kind and right stick survive")
        try expect(padBack.command == 3 && padBack.commandSerial == 9, "request survives")
        let status = RemoteControllerStatus(player: 3, rumble: false, gameplay: false,
                                            startingMultiplayer: true, playerCount: 4)
        try expect(RemoteControllerStatus(status.encoded()) == status, "multiplayer status and player count survive")

        // Slots: first come, first served; a fifth waits; swaps move both.
        var slots = RemotePlayerSlots()
        let phones = (0..<5).map { _ in UUID() }
        try expect(slots.join(phones[0]) == 0, "first controller is player 1")
        try expect(slots.join(phones[1]) == 1 && slots.join(phones[2]) == 2 && slots.join(phones[3]) == 3, "then 2, 3, 4")
        try expect(slots.join(phones[4]) == nil, "fifth waits: all players taken")
        try expect(slots.join(phones[0]) == 0, "rejoin keeps the same player")
        try expect(slots.seat(phones[3], at: 0) == phones[0], "player 4 asks for player 1: player 1 moves out")
        try expect(slots.port(of: phones[3]) == 0 && slots.port(of: phones[0]) == 3, "they swapped")
        slots.leave(phones[1])
        try expect(slots.seat(phones[2], at: 1) == nil, "moving to a free player displaces no one")
        try expect(slots.owners[2] == nil, "and frees the old one")

        try mixerTests()
        try quickStartTests()
        print("PASS: remote controller protocol, status, player slots and mixer")
    }

    static func mixerTests() throws {
        var mixer = RemotePlayerMixer()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        // No game controller on the TV: phones are players 1-4, the fifth waits.
        try expect(mixer.connect(a) == 0, "first phone is player 1")
        try expect(mixer.connect(b) == 1, "second phone is player 2")
        try expect(mixer.connect(c) == 2 && mixer.connect(d) == 3, "phones three and four are players 3 and 4")
        try expect(mixer.connect(e) == nil, "fifth phone waits")
        try expect(mixer.portMask == 0xF, "all four ports are held by phones")

        // Buttons, sticks, look and presses reach the right player.
        var input = RemoteControllerInput()
        input.buttons = 0x2000
        input.stick = SIMD2(0, 1)
        input.look = SIMD2(0.1, 0)
        input.crouchPresses = 254
        mixer.receive(input, from: b, now: 10)
        input.look = SIMD2(0.2, 0)
        input.crouchPresses = 1 // wrapped: three presses since 254
        mixer.receive(input, from: b, now: 10.01)
        var frames = mixer.drain(now: 10.02)
        guard let p2 = frames.first(where: { $0.port == 1 }) else {
            throw ProtocolTestFailure(description: "player 2 has a frame")
        }
        try expect(p2.buttons == 0x2000 && near(p2.stick.y, 1), "player 2 buttons and stick")
        try expect(near(p2.look.x, 0.3), "look from both frames adds up")
        try expect(p2.crouchPresses == 3, "crouch presses counted across the wrap")
        frames = mixer.drain(now: 10.03)
        let again = frames.first(where: { $0.port == 1 })
        try expect(again?.look == .zero && again?.crouchPresses == 0, "look and presses are delivered once")
        try expect(again?.buttons == 0x2000, "held buttons stay held")
        try expect(frames.first(where: { $0.port == 0 })?.buttons == 0, "player 1 sent nothing: neutral")

        // A phone that goes quiet is let go.
        frames = mixer.drain(now: 11)
        try expect(frames.first(where: { $0.port == 1 })?.buttons == 0, "stale phone reads as neutral")

        // Leaving frees the player for the waiting phone.
        try expect(mixer.disconnect(c) == [e], "the waiting phone is seated")
        try expect(mixer.port(of: e) == 2, "waiting phone takes the freed player 3")

        // A gamepad paired with the TV joins like a phone, in arrival order.
        _ = mixer.disconnect(a)
        let tvPad = UUID()
        try expect(mixer.connect(tvPad, localGamepad: true) == 0, "TV gamepad takes the free player 1")
        try expect(mixer.isLocalGamepad(tvPad) && !mixer.isLocalGamepad(b), "it is known as the TV's own")

        // Player 3 (e) asks to be player 1: they swap, once per request.
        var request = RemoteControllerInput()
        request.command = RemoteControllerCommand.becomePlayer(0)
        request.commandSerial = 0
        try expect(mixer.receive(request, from: e, now: 20).isEmpty, "first frame only sets the baseline")
        request.commandSerial = 1
        let swapped = mixer.receive(request, from: e, now: 20.01)
        try expect(Set(swapped) == [e, tvPad], "both swapped controllers are reported")
        try expect(mixer.port(of: e) == 0 && mixer.port(of: tvPad) == 2, "player 1 and player 3 traded places")
        try expect(mixer.receive(request, from: e, now: 20.02).isEmpty, "a repeated frame does not repeat the swap")

        // Start multiplayer is handed over exactly once.
        request.command = RemoteControllerCommand.startMultiplayer
        request.commandSerial = 2
        mixer.receive(request, from: b, now: 20.03)
        try expect(mixer.takeMultiplayerRequest(), "multiplayer request arrives")
        try expect(!mixer.takeMultiplayerRequest(), "and only once")

        // Gaps close before multiplayer, keeping the order.
        var gappy = RemotePlayerMixer()
        let g1 = UUID(), g2 = UUID(), g3 = UUID()
        gappy.connect(g1); gappy.connect(g2); gappy.connect(g3)
        gappy.disconnect(g1)
        try expect(gappy.portMask == 0b110, "players 2 and 3 left with a gap at 1")
        try expect(Set(gappy.compact()) == [g2, g3], "both move down")
        try expect(gappy.port(of: g2) == 0 && gappy.port(of: g3) == 1, "now players 1 and 2, same order")

        // Gamepad look is a position: it stays while held and is not summed.
        var stick = RemoteControllerInput()
        stick.kind = .gamepad
        stick.look = SIMD2(0.5, 0)
        mixer.receive(stick, from: b, now: 30)
        mixer.receive(stick, from: b, now: 30.01)
        frames = mixer.drain(now: 30.02)
        try expect(frames.first(where: { $0.port == 1 })?.look == SIMD2(0.5, 0), "right stick is not summed")
        frames = mixer.drain(now: 30.03)
        try expect(frames.first(where: { $0.port == 1 })?.kind == .gamepad, "frame says gamepad")
        try expect(frames.first(where: { $0.port == 1 })?.look == SIMD2(0.5, 0), "held right stick stays held")
        frames = mixer.drain(now: 31)
        try expect(frames.first(where: { $0.port == 1 })?.look == .zero, "stale gamepad lets go of the right stick")
    }

    static func quickStartTests() throws {
        // Fewer than two players: refuse.
        var alone = RemoteMultiplayerQuickStart()
        _ = alone.step(screen: 5, cursor: 0, players: 1)
        if case .failed = alone.outcome {} else { throw ProtocolTestFailure(description: "one player cannot start multiplayer") }

        // From the file screen: Start, then down to Multiplayer, then Start.
        var quick = RemoteMultiplayerQuickStart()
        var step = quick.step(screen: 5, cursor: 0, players: 2)
        try expect(step.press.buttons == 0x1000, "file screen: Start")
        for _ in 0..<40 { _ = quick.step(screen: 6, cursor: 200, players: 2) }
        step = quick.step(screen: 6, cursor: 200, players: 2)
        try expect(step.press.stick.y < 0 && step.press.buttons == 0, "mode screen above Multiplayer: push down")
        step = quick.step(screen: 6, cursor: 290, players: 2)
        try expect(step.press.stick.y > 0, "below Multiplayer (cheats): push up")
        step = quick.step(screen: 6, cursor: 250, players: 2)
        try expect(step.press.buttons == 0x1000 && step.press.stick == .zero, "on Multiplayer: Start")
        for _ in 0..<40 { _ = quick.step(screen: 6, cursor: 250, players: 2) }
        _ = quick.step(screen: 14, cursor: 250, players: 2)
        try expect(quick.outcome == .done, "multiplayer setup reached")

        // In a level: ask once to return to the title, never press there.
        var inLevel = RemoteMultiplayerQuickStart()
        step = inLevel.step(screen: 11, cursor: 0, players: 3)
        try expect(step.returnToTitle && step.press.buttons == 0, "level: return to title")
        var askedAgain = false
        for _ in 0..<200 {
            let next = inLevel.step(screen: 11, cursor: 0, players: 3)
            askedAgain = askedAgain || next.returnToTitle || next.press.buttons != 0
        }
        try expect(!askedAgain, "no second request and no presses inside the level")

        // Gives up eventually.
        var stuck = RemoteMultiplayerQuickStart(timeout: 10)
        for _ in 0..<12 { _ = stuck.step(screen: 7, cursor: 0, players: 2) }
        if case .failed = stuck.outcome {} else { throw ProtocolTestFailure(description: "times out") }
    }
}
