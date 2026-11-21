import Foundation

/// "Start multiplayer" on the Apple TV: drives GoldenEye's own front end as
/// Player 1 would, one tick at a time, from wherever it is to the
/// multiplayer setup screen. It reads the game's current screen each tick
/// rather than following a fixed script, so a skipped press or a slow
/// screen change only delays it.
///
/// GoldenEye shows Multiplayer on its mode screen (after a save file is
/// picked) only while at least two controllers are plugged in, counted from
/// Player 1 up without gaps, and only Player 1 drives the menus.
struct RemoteMultiplayerQuickStart {
    /// GoldenEye's `current_menu` values (the MENU enum).
    enum Screen {
        static let lastIntro = 4          // legal, Nintendo, Rare, eye intro, GoldenEye logo
        static let fileSelect = 5
        static let modeSelect = 6
        static let level = 11
        static let missionFailed = 12
        static let missionComplete = 13
        static let multiplayerOptions = 14
        static let lastMultiplayer = 20   // MP options ... MP teams
        static let noControllers = 23
    }

    /// Mode screen cursor: Multiplayer is highlighted from 243 down to the
    /// cheats row at 275.
    static let multiplayerRow: ClosedRange<Float> = 243...274

    enum Outcome: Equatable {
        case running
        case done
        case failed(String)
    }

    /// Player 1's buttons and stick for this tick.
    struct Press: Equatable {
        var buttons: UInt16 = 0
        var stick = SIMD2<Float>.zero
    }

    static let start: UInt16 = 0x1000

    private(set) var outcome = Outcome.running
    private var ticks = 0
    private var pressTicks = 0
    private var waitTicks = 0
    private var askedForTitle = false
    /// Give up after this many ticks (60 a second).
    let timeout: Int

    init(timeout: Int = 60 * 45) {
        self.timeout = timeout
    }

    /// One tick. `screen` is nil while the game is not running. Returns what
    /// Player 1 presses; `returnToTitle` is set once when a level must be
    /// left first.
    mutating func step(screen: Int?, cursor: Float, players: Int) -> (press: Press, returnToTitle: Bool) {
        guard outcome == .running else { return (Press(), false) }
        ticks += 1
        if ticks > timeout {
            outcome = .failed("GoldenEye did not reach the multiplayer screen. Try it from the menus with Player 1.")
            return (Press(), false)
        }
        guard players >= 2 else {
            outcome = .failed("Multiplayer needs at least two players. Join with another iPhone or controller first.")
            return (Press(), false)
        }
        guard let screen else { return (Press(), false) }
        if (Screen.multiplayerOptions...Screen.lastMultiplayer).contains(screen) {
            outcome = .done
            return (Press(), false)
        }
        if screen == Screen.noControllers {
            outcome = .failed("GoldenEye says no controllers are connected.")
            return (Press(), false)
        }
        // A press is held for 4 ticks, then released for 26, so GoldenEye
        // sees each one as a separate press.
        if pressTicks > 0 {
            pressTicks -= 1
            return (Press(buttons: Self.start), false)
        }
        if waitTicks > 0 {
            waitTicks -= 1
            return (Press(), false)
        }
        switch screen {
        case Screen.level, Screen.missionFailed, Screen.missionComplete:
            // Leave the level first (GoldenPad's own return to title).
            if !askedForTitle {
                askedForTitle = true
                waitTicks = 90
                return (Press(), true)
            }
            return (Press(), false)
        case Screen.modeSelect:
            if Self.multiplayerRow.contains(cursor) {
                return (press(), false)
            }
            // Pushing the stick down moves the cursor down (larger values).
            return (Press(stick: SIMD2(0, cursor < Self.multiplayerRow.lowerBound ? -0.8 : 0.8)), false)
        case 0...Screen.fileSelect:
            // Intro screens skip with Start; on the file screen Start opens
            // the highlighted save file.
            return (press(), false)
        default:
            // Mission select, difficulty, briefing and the like: back out
            // to the title and come round again.
            if !askedForTitle {
                askedForTitle = true
                waitTicks = 90
                return (Press(), true)
            }
            return (Press(), false)
        }
    }

    private mutating func press() -> Press {
        pressTicks = 3
        waitTicks = 26
        return Press(buttons: Self.start)
    }
}
