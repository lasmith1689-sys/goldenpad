import Foundation
import GameController

/// Turns a real gamepad into a controller frame: the same Fire/Aim/Action/
/// Weapon/Start/D-pad bits the touch controls send, the left stick, the raw
/// right stick, and crouch and reload press counters. Used for a gamepad
/// held in (or paired with) a phone that is a controller for an Apple TV,
/// and for each gamepad paired with the Apple TV itself, so every player is
/// handled the same way on the TV.
struct RecompGamepadReader {
    private var crouchPresses: UInt8 = 0
    private var reloadPresses: UInt8 = 0
    private var crouchWasPressed = false
    private var reloadWasPressed = false

    private enum N64 {
        static let a: UInt16 = 0x8000
        static let b: UInt16 = 0x4000
        static let z: UInt16 = 0x2000
        static let start: UInt16 = 0x1000
        static let dpadUp: UInt16 = 0x0800
        static let dpadDown: UInt16 = 0x0400
        static let dpadLeft: UInt16 = 0x0200
        static let dpadRight: UInt16 = 0x0100
        static let r: UInt16 = 0x0010
    }

    mutating func read(
        _ gamepad: GCExtendedGamepad,
        mapping: [RecompPrototypeControllerControl: RecompPrototypeControllerAction]
    ) -> RemoteControllerInput {
        var input = RemoteControllerInput()
        input.kind = .gamepad
        input.stick = SIMD2(gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value)
        input.look = SIMD2(gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value)
        let pressed: [(RecompPrototypeControllerControl, Bool)] = [
            (.buttonA, gamepad.buttonA.isPressed),
            (.buttonB, gamepad.buttonB.isPressed),
            (.buttonX, gamepad.buttonX.isPressed),
            (.buttonY, gamepad.buttonY.isPressed),
            (.leftShoulder, gamepad.leftShoulder.isPressed),
            (.rightShoulder, gamepad.rightShoulder.isPressed),
            (.leftTrigger, gamepad.leftTrigger.value > 0.25),
            (.rightTrigger, gamepad.rightTrigger.value > 0.25),
        ]
        var crouch = false
        var reload = false
        for (control, isPressed) in pressed where isPressed {
            switch mapping[control] ?? control.defaultAction {
            case .fire: input.buttons |= N64.z
            case .aim: input.buttons |= N64.r
            case .action: input.buttons |= N64.b
            case .weapon: input.buttons |= N64.a
            case .reload: reload = true
            case .duck: crouch = true
            case .none: break
            }
        }
        if gamepad.buttonMenu.isPressed { input.buttons |= N64.start }
        if gamepad.dpad.up.isPressed { input.buttons |= N64.dpadUp }
        if gamepad.dpad.down.isPressed { input.buttons |= N64.dpadDown }
        if gamepad.dpad.left.isPressed { input.buttons |= N64.dpadLeft }
        if gamepad.dpad.right.isPressed { input.buttons |= N64.dpadRight }
        if crouch && !crouchWasPressed { crouchPresses &+= 1 }
        if reload && !reloadWasPressed { reloadPresses &+= 1 }
        crouchWasPressed = crouch
        reloadWasPressed = reload
        input.crouchPresses = crouchPresses
        input.reloadPresses = reloadPresses
        return input
    }
}
