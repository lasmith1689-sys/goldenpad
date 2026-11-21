import Foundation

/// Wire format between an iPhone acting as a controller and the Apple TV
/// running the game (Bonjour `_gpad-ctrl._tcp`, one TCP connection per phone).
/// Every message is a fixed-size little-endian frame, so the stream needs no
/// other framing.
enum RemoteControllerWire {
    static let serviceType = "_gpad-ctrl._tcp"
    static let version: UInt8 = 1
    static let maxPlayers = 4
}

/// What drives a player: touch controls on a phone, or a real gamepad (one
/// held in or paired with a phone, or paired with the TV itself).
enum RemoteControllerKind: UInt8, Equatable {
    /// `look` is relative look movement since the previous frame.
    case touch = 0
    /// `look` is the right stick's position; the TV shapes it like its own
    /// gamepad (dead zone, curve, aim speed, full-tilt turn boost).
    case gamepad = 1
}

/// One-shot requests a phone can make, carried in input frames and run by
/// the TV once per new `commandSerial`.
enum RemoteControllerCommand {
    static let none: UInt8 = 0
    /// 1...4: become that player, swapping with whoever has it.
    static func becomePlayer(_ port: Int) -> UInt8 { UInt8(port + 1) }
    /// Take GoldenEye's front end to the multiplayer setup screen.
    static let startMultiplayer: UInt8 = 0x20
}

/// Phone -> TV, sent about 60 times a second. Buttons use the same N64 bit
/// layout as GoldenPad's touch controls (Z fire, R aim, B action, A weapon,
/// Start, D-pad), so the TV maps them exactly as it maps local touch input.
struct RemoteControllerInput: Equatable {
    static let size = 16

    var kind = RemoteControllerKind.touch
    var buttons: UInt16 = 0
    /// Movement stick, -1...1 on each axis.
    var stick = SIMD2<Float>.zero
    /// Touch: look movement since the previous frame (already amplified like
    /// touch look). Gamepad: the right stick, -1...1.
    var look = SIMD2<Float>.zero
    /// Increments once per crouch press; the TV toggles crouch on each change.
    var crouchPresses: UInt8 = 0
    /// Increments once per reload press.
    var reloadPresses: UInt8 = 0
    /// The latest request (`RemoteControllerCommand`), repeated in every frame.
    var command: UInt8 = RemoteControllerCommand.none
    /// Changes once per new request, so a repeated frame never repeats it.
    var commandSerial: UInt8 = 0

    func encoded() -> Data {
        var data = Data(capacity: Self.size)
        data.append(RemoteControllerWire.version)
        data.append(kind.rawValue)
        append(buttons, to: &data)
        append(Self.quantize(stick.x), to: &data)
        append(Self.quantize(stick.y), to: &data)
        append(Self.quantize(look.x), to: &data)
        append(Self.quantize(look.y), to: &data)
        data.append(crouchPresses)
        data.append(reloadPresses)
        data.append(command)
        data.append(commandSerial)
        return data
    }

    init() {}

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.size, bytes[0] == RemoteControllerWire.version else { return nil }
        kind = RemoteControllerKind(rawValue: bytes[1]) ?? .touch
        buttons = Self.read(bytes, 2)
        stick = SIMD2(Self.dequantize(Self.read(bytes, 4)), Self.dequantize(Self.read(bytes, 6)))
        look = SIMD2(Self.dequantize(Self.read(bytes, 8)), Self.dequantize(Self.read(bytes, 10)))
        crouchPresses = bytes[12]
        reloadPresses = bytes[13]
        command = bytes[14]
        commandSerial = bytes[15]
    }

    private static func quantize(_ value: Float) -> UInt16 {
        UInt16(bitPattern: Int16((min(max(value, -1), 1) * 32_767).rounded()))
    }

    private static func dequantize(_ raw: UInt16) -> Float {
        Float(Int16(bitPattern: raw)) / 32_767
    }

    private static func read(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }
}

/// TV -> phone: which player this phone is, whether its rumble motor is on,
/// whether that player is in gameplay (not in menus or behind the watch),
/// how many players are seated, and whether the TV is taking the game to
/// the multiplayer screen.
struct RemoteControllerStatus: Equatable {
    static let size = 4

    /// 0...3, or nil while the TV has no free player for this phone.
    var player: Int?
    var rumble = false
    /// The player is moving around a level (byte 3, bit 0; older TVs send 0).
    var gameplay = false
    /// The TV is driving the menus to multiplayer setup (bit 1).
    var startingMultiplayer = false
    /// Players seated on the TV, 0...4 (bits 4-6).
    var playerCount = 0

    func encoded() -> Data {
        var flags: UInt8 = 0
        if gameplay { flags |= 1 }
        if startingMultiplayer { flags |= 2 }
        flags |= UInt8(min(max(playerCount, 0), 7)) << 4
        return Data([RemoteControllerWire.version, UInt8(player ?? 0xFF), rumble ? 1 : 0, flags])
    }

    init(player: Int?, rumble: Bool, gameplay: Bool = false,
         startingMultiplayer: Bool = false, playerCount: Int = 0) {
        self.player = player
        self.rumble = rumble
        self.gameplay = gameplay
        self.startingMultiplayer = startingMultiplayer
        self.playerCount = playerCount
    }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.size, bytes[0] == RemoteControllerWire.version else { return nil }
        player = bytes[1] == 0xFF ? nil : Int(bytes[1])
        rumble = bytes[2] != 0
        gameplay = bytes[3] & 1 != 0
        startingMultiplayer = bytes[3] & 2 != 0
        playerCount = Int((bytes[3] >> 4) & 7)
    }
}

/// Which controller holds which player. Players go first come, first served,
/// and are kept until the controller leaves or swaps.
struct RemotePlayerSlots: Equatable {
    private(set) var owners: [Int: UUID] = [:]

    func port(of id: UUID) -> Int? {
        owners.first(where: { $0.value == id })?.key
    }

    /// Joins `id` as the lowest free player. Returns it, or nil when all
    /// four are taken.
    mutating func join(_ id: UUID) -> Int? {
        if let existing = port(of: id) { return existing }
        for port in 0..<RemoteControllerWire.maxPlayers where owners[port] == nil {
            owners[port] = id
            return port
        }
        return nil
    }

    /// Puts `id` on `port`. Whoever had that player takes `id`'s old one (or,
    /// if `id` had none, is left waiting). Returns the controller that moved
    /// out of the way, if any.
    @discardableResult
    mutating func seat(_ id: UUID, at port: Int) -> UUID? {
        guard (0..<RemoteControllerWire.maxPlayers).contains(port) else { return nil }
        let previous = self.port(of: id)
        guard previous != port else { return nil }
        let displaced = owners[port]
        if let previous { owners[previous] = displaced }
        owners[port] = id
        return displaced
    }

    mutating func leave(_ id: UUID) {
        if let port = port(of: id) { owners[port] = nil }
    }

    var occupiedPorts: [Int] { owners.keys.sorted() }
}

/// One player's input for one 60 Hz tick on the TV.
struct RemotePlayerFrame: Equatable {
    var port: Int
    var kind: RemoteControllerKind
    var buttons: UInt16
    var stick: SIMD2<Float>
    /// Touch: look movement gathered since the previous tick. Gamepad: the
    /// right stick's position.
    var look: SIMD2<Float>
    /// Crouch presses since the previous tick (each one toggles crouch).
    var crouchPresses: Int
    var reloadPresses: Int
}

/// Everything the TV knows about the controllers playing on it (phones over
/// the network and gamepads paired with the TV), without any networking, so
/// it can be tested on its own: which player each is, its latest buttons and
/// sticks, the look and presses still to deliver, and requests to swap
/// players or start multiplayer.
struct RemotePlayerMixer {
    /// A phone that has sent nothing for this long counts as let go.
    static let staleAfter: TimeInterval = 0.5

    private struct Member {
        var isLocalGamepad: Bool
        var latest = RemoteControllerInput()
        var receivedAt: TimeInterval = -.infinity
        var look = SIMD2<Float>.zero
        var lastCrouch: UInt8?
        var lastReload: UInt8?
        var lastCommandSerial: UInt8?
        var crouchPresses = 0
        var reloadPresses = 0
    }

    private(set) var slots = RemotePlayerSlots()
    private var members: [UUID: Member] = [:]
    /// Connection order, so a controller waiting for a free player is served first-come.
    private var order: [UUID] = []
    private var multiplayerRequested = false

    func port(of id: UUID) -> Int? { slots.port(of: id) }

    var connectedCount: Int { order.count }

    /// True for a gamepad paired with the TV, false for a phone.
    func isLocalGamepad(_ id: UUID) -> Bool { members[id]?.isLocalGamepad ?? false }

    /// What the controller last sent: touch controls or a gamepad.
    func latestKind(of id: UUID) -> RemoteControllerKind { members[id]?.latest.kind ?? .touch }

    /// Port mask (bit n = player n+1) of seated players.
    var portMask: Int32 {
        slots.occupiedPorts.reduce(Int32(0)) { $0 | (Int32(1) << Int32($1)) }
    }

    /// A phone connected, or a gamepad was paired with the TV
    /// (`localGamepad`). Returns its player, or nil while all are taken.
    @discardableResult
    mutating func connect(_ id: UUID, localGamepad: Bool = false) -> Int? {
        if members[id] == nil {
            members[id] = Member(isLocalGamepad: localGamepad)
            order.append(id)
        }
        return slots.join(id)
    }

    /// A controller left. Returns the waiting controllers given its player.
    @discardableResult
    mutating func disconnect(_ id: UUID) -> [UUID] {
        slots.leave(id)
        members[id] = nil
        order.removeAll { $0 == id }
        return fillFreePlayers()
    }

    /// Moves `id` to `port`, swapping with its holder. Returns every
    /// controller whose player changed.
    @discardableResult
    mutating func seat(_ id: UUID, at port: Int) -> [UUID] {
        guard members[id] != nil, slots.port(of: id) != port else { return [] }
        let displaced = slots.seat(id, at: port)
        var changed = [id]
        if let displaced { changed.append(displaced) }
        return changed + fillFreePlayers()
    }

    /// Takes a new input frame. Returns the controllers whose player changed
    /// because of a request in it.
    @discardableResult
    mutating func receive(_ input: RemoteControllerInput, from id: UUID, now: TimeInterval) -> [UUID] {
        guard var member = members[id] else { return [] }
        member.latest = input
        member.receivedAt = now
        switch input.kind {
        case .touch:
            // Cap what one phone can queue between ticks (a fast flick is ~1).
            let look = member.look + input.look
            let length = (look * look).sum().squareRoot()
            member.look = length > 4 ? look * (4 / length) : look
        case .gamepad:
            member.look = input.look
        }
        // Counters only ever grow (wrapping at 256): the difference since
        // the last frame is how many presses happened, so a merged frame
        // never loses a press. The first frame sets the baseline.
        if let last = member.lastCrouch { member.crouchPresses += Int(input.crouchPresses &- last) }
        if let last = member.lastReload { member.reloadPresses += Int(input.reloadPresses &- last) }
        member.lastCrouch = input.crouchPresses
        member.lastReload = input.reloadPresses
        let newCommand = member.lastCommandSerial.map { $0 != input.commandSerial } ?? false
        member.lastCommandSerial = input.commandSerial
        members[id] = member
        guard newCommand else { return [] }
        switch input.command {
        case 1...UInt8(RemoteControllerWire.maxPlayers):
            return seat(id, at: Int(input.command) - 1)
        case RemoteControllerCommand.startMultiplayer:
            multiplayerRequested = true
            return []
        default:
            return []
        }
    }

    /// Closes gaps (players 1, 3 become 1, 2), keeping everyone's order.
    /// GoldenEye counts controllers from Player 1 up and stops at the first
    /// empty port. Returns the controllers whose player changed.
    @discardableResult
    mutating func compact() -> [UUID] {
        var changed: [UUID] = []
        for (index, port) in slots.occupiedPorts.enumerated() where index != port {
            guard let id = slots.owners[port] else { continue }
            slots.seat(id, at: index)
            changed.append(id)
        }
        return changed
    }

    /// True once after a controller asked to start multiplayer.
    mutating func takeMultiplayerRequest() -> Bool {
        defer { multiplayerRequested = false }
        return multiplayerRequested
    }

    /// Gives waiting controllers any free player, oldest first. Returns them.
    private mutating func fillFreePlayers() -> [UUID] {
        var seated: [UUID] = []
        for id in order where slots.port(of: id) == nil {
            if slots.join(id) != nil { seated.append(id) }
        }
        return seated
    }

    /// This tick's input for every seated controller, clearing the look and
    /// presses it has now delivered.
    mutating func drain(now: TimeInterval) -> [RemotePlayerFrame] {
        var frames: [RemotePlayerFrame] = []
        for port in slots.occupiedPorts {
            guard let id = slots.owners[port], var member = members[id] else { continue }
            let fresh = now - member.receivedAt <= Self.staleAfter
            let kind = member.latest.kind
            frames.append(RemotePlayerFrame(
                port: port,
                kind: kind,
                buttons: fresh ? member.latest.buttons : 0,
                stick: fresh ? member.latest.stick : .zero,
                look: kind == .gamepad && !fresh ? .zero : member.look,
                crouchPresses: member.crouchPresses,
                reloadPresses: member.reloadPresses))
            if kind == .touch { member.look = .zero }
            member.crouchPresses = 0
            member.reloadPresses = 0
            members[id] = member
        }
        return frames
    }
}
