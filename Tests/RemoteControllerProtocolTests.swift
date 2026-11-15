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
        for status in [RemoteControllerStatus(player: 2, rumble: true), RemoteControllerStatus(player: nil, rumble: false)] {
            guard let back = RemoteControllerStatus(status.encoded()) else {
                throw ProtocolTestFailure(description: "status frame decodes")
            }
            try expect(back == status, "status survives: \(status)")
        }

        // Slots: the TV's gamepad keeps player 1; phones fill 2-4, then none.
        var slots = RemotePlayerSlots()
        let phones = (0..<4).map { _ in UUID() }
        try expect(slots.join(phones[0], reservedPort: 0) == 1, "first phone is player 2 beside a gamepad")
        try expect(slots.join(phones[1], reservedPort: 0) == 2, "second phone is player 3")
        try expect(slots.join(phones[2], reservedPort: 0) == 3, "third phone is player 4")
        try expect(slots.join(phones[3], reservedPort: 0) == nil, "fourth phone waits: all players taken")
        try expect(slots.join(phones[0], reservedPort: 0) == 1, "rejoin keeps the same player")
        slots.leave(phones[1])
        try expect(slots.join(phones[3], reservedPort: 0) == 2, "a freed player is reused")

        // Without a gamepad, the first phone is player 1.
        var phonesOnly = RemotePlayerSlots()
        try expect(phonesOnly.join(UUID(), reservedPort: nil) == 0, "first phone is player 1 with no gamepad")

        try mixerTests()
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

        // Pairing a game controller with the TV takes player 1 back.
        let moved = mixer.setReservedPort(0)
        try expect(mixer.port(of: a) == nil && moved.contains(a), "phone on player 1 makes way for the gamepad")
        try expect(mixer.portMask & 1 == 0, "player 1 is no longer a phone")
        try expect(mixer.disconnect(d) == [a], "the displaced phone is seated again")
        try expect(mixer.port(of: a) == 3, "the displaced phone gets the free player 4")
        _ = mixer.setReservedPort(nil)
        try expect(mixer.connectedCount == 3, "three phones still connected")
    }
}
