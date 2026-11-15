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

/// Phone -> TV, sent about 60 times a second. Buttons use the same N64 bit
/// layout as GoldenPad's touch controls (Z fire, R aim, B action, A weapon,
/// Start), so the TV maps them exactly as it maps local touch input.
struct RemoteControllerInput: Equatable {
    static let size = 16

    var buttons: UInt16 = 0
    /// Movement stick, -1...1 on each axis.
    var stick = SIMD2<Float>.zero
    /// Look movement since the previous frame (already amplified like touch look).
    var look = SIMD2<Float>.zero
    /// Increments once per crouch press; the TV toggles crouch on each change.
    var crouchPresses: UInt8 = 0
    /// Increments once per reload press.
    var reloadPresses: UInt8 = 0

    func encoded() -> Data {
        var data = Data(capacity: Self.size)
        data.append(RemoteControllerWire.version)
        data.append(0) // reserved
        append(buttons, to: &data)
        append(Self.quantize(stick.x), to: &data)
        append(Self.quantize(stick.y), to: &data)
        append(Self.quantize(look.x), to: &data)
        append(Self.quantize(look.y), to: &data)
        data.append(crouchPresses)
        data.append(reloadPresses)
        data.append(contentsOf: [0, 0])
        return data
    }

    init() {}

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.size, bytes[0] == RemoteControllerWire.version else { return nil }
        buttons = Self.read(bytes, 2)
        stick = SIMD2(Self.dequantize(Self.read(bytes, 4)), Self.dequantize(Self.read(bytes, 6)))
        look = SIMD2(Self.dequantize(Self.read(bytes, 8)), Self.dequantize(Self.read(bytes, 10)))
        crouchPresses = bytes[12]
        reloadPresses = bytes[13]
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

/// TV -> phone: which player this phone is, and whether its rumble motor is on.
struct RemoteControllerStatus: Equatable {
    static let size = 4

    /// 0...3, or nil while the TV has no free player for this phone.
    var player: Int?
    var rumble = false

    func encoded() -> Data {
        Data([RemoteControllerWire.version, UInt8(player ?? 0xFF), rumble ? 1 : 0, 0])
    }

    init(player: Int?, rumble: Bool) {
        self.player = player
        self.rumble = rumble
    }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.size, bytes[0] == RemoteControllerWire.version else { return nil }
        player = bytes[1] == 0xFF ? nil : Int(bytes[1])
        rumble = bytes[2] != 0
    }
}

/// Assigns players to joining controllers: a paired gamepad on the TV keeps
/// player 1; phones take the lowest free player and keep it until they leave.
struct RemotePlayerSlots: Equatable {
    private(set) var owners: [Int: UUID] = [:]

    func port(of id: UUID) -> Int? {
        owners.first(where: { $0.value == id })?.key
    }

    /// Joins `id`, skipping `reservedPort` (the TV's own gamepad). Returns the
    /// player port, or nil when all four are taken.
    mutating func join(_ id: UUID, reservedPort: Int?) -> Int? {
        if let existing = port(of: id) { return existing }
        for port in 0..<RemoteControllerWire.maxPlayers where owners[port] == nil && port != reservedPort {
            owners[port] = id
            return port
        }
        return nil
    }

    mutating func leave(_ id: UUID) {
        if let port = port(of: id) { owners[port] = nil }
    }

    var occupiedPorts: [Int] { owners.keys.sorted() }
}

/// One player's input for one 60 Hz tick on the TV.
struct RemotePlayerFrame: Equatable {
    var port: Int
    var buttons: UInt16
    var stick: SIMD2<Float>
    /// Look movement gathered since the previous tick.
    var look: SIMD2<Float>
    /// Crouch presses since the previous tick (each one toggles crouch).
    var crouchPresses: Int
    var reloadPresses: Int
}

/// Everything the TV knows about connected phones, without any networking,
/// so it can be tested on its own: which player each phone is, its latest
/// buttons and sticks, and the look and button presses still to deliver.
struct RemotePlayerMixer {
    /// A phone that has sent nothing for this long counts as let go.
    static let staleAfter: TimeInterval = 0.5

    private struct Phone {
        var latest = RemoteControllerInput()
        var receivedAt: TimeInterval = -.infinity
        var look = SIMD2<Float>.zero
        var lastCrouch: UInt8?
        var lastReload: UInt8?
        var crouchPresses = 0
        var reloadPresses = 0
    }

    private(set) var slots = RemotePlayerSlots()
    private var phones: [UUID: Phone] = [:]
    /// Connection order, so a phone waiting for a free player is served first-come.
    private var order: [UUID] = []
    /// The player held by a game controller paired with the TV (0), if any.
    private(set) var reservedPort: Int?

    func port(of id: UUID) -> Int? { slots.port(of: id) }

    var connectedCount: Int { order.count }

    /// Port mask (bit n = player n+1) of players held by phones.
    var portMask: Int32 {
        slots.occupiedPorts.reduce(Int32(0)) { $0 | (Int32(1) << Int32($1)) }
    }

    /// A phone connected. Returns its player, or nil while all are taken.
    @discardableResult
    mutating func connect(_ id: UUID) -> Int? {
        if phones[id] == nil {
            phones[id] = Phone()
            order.append(id)
        }
        return slots.join(id, reservedPort: reservedPort)
    }

    /// A phone left. Returns the waiting phones that were given its player.
    @discardableResult
    mutating func disconnect(_ id: UUID) -> [UUID] {
        slots.leave(id)
        phones[id] = nil
        order.removeAll { $0 == id }
        return fillFreePlayers()
    }

    mutating func receive(_ input: RemoteControllerInput, from id: UUID, now: TimeInterval) {
        guard var phone = phones[id] else { return }
        phone.latest = input
        phone.receivedAt = now
        phone.look += input.look
        // Counters only ever grow (wrapping at 256): the difference since
        // the last frame is how many presses happened, so a merged frame
        // never loses a press. The first frame sets the baseline.
        if let last = phone.lastCrouch { phone.crouchPresses += Int(input.crouchPresses &- last) }
        if let last = phone.lastReload { phone.reloadPresses += Int(input.reloadPresses &- last) }
        phone.lastCrouch = input.crouchPresses
        phone.lastReload = input.reloadPresses
        phones[id] = phone
    }

    /// A game controller was paired or unpaired with the TV. It always gets
    /// player 1; a phone that held player 1 moves to the next free player.
    /// Returns the phones whose player changed.
    mutating func setReservedPort(_ port: Int?) -> [UUID] {
        guard port != reservedPort else { return [] }
        reservedPort = port
        var moved: [UUID] = []
        if let port, let holder = slots.owners[port] {
            slots.leave(holder)
            _ = slots.join(holder, reservedPort: port)
            moved.append(holder)
        }
        return moved + fillFreePlayers()
    }

    /// Gives waiting phones any free player, oldest first. Returns those phones.
    private mutating func fillFreePlayers() -> [UUID] {
        var seated: [UUID] = []
        for id in order where slots.port(of: id) == nil {
            if slots.join(id, reservedPort: reservedPort) != nil { seated.append(id) }
        }
        return seated
    }

    /// This tick's input for every seated phone, clearing the look and
    /// presses it has now delivered.
    mutating func drain(now: TimeInterval) -> [RemotePlayerFrame] {
        var frames: [RemotePlayerFrame] = []
        for port in slots.occupiedPorts {
            guard let id = slots.owners[port], var phone = phones[id] else { continue }
            let fresh = now - phone.receivedAt <= Self.staleAfter
            frames.append(RemotePlayerFrame(
                port: port,
                buttons: fresh ? phone.latest.buttons : 0,
                stick: fresh ? phone.latest.stick : .zero,
                look: phone.look,
                crouchPresses: phone.crouchPresses,
                reloadPresses: phone.reloadPresses))
            phone.look = .zero
            phone.crouchPresses = 0
            phone.reloadPresses = 0
            phones[id] = phone
        }
        return frames
    }
}
