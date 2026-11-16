import Foundation

// Checks that an Apple TV save survives tvOS clearing Caches: the mirror keeps
// the save files in UserDefaults and writes them back when they go missing.
// Uses random bytes standing in for a save (no game data).
// Build: swiftc Sources/GoldenPadSaveMirror.swift Tests/GoldenPadSaveMirrorTests.swift -parse-as-library

@main
struct GoldenPadSaveMirrorTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("ok: \(message)")
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    static func main() throws {
        let suite = "goldenpad.saveMirrorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-mirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let saves = root.appendingPathComponent("GoldenPadRecomp/saves", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: saves, withIntermediateDirectories: true)

        let save = random(512), backup = random(512)
        try save.write(to: saves.appendingPathComponent("ge007.us.bin"))
        try backup.write(to: saves.appendingPathComponent("ge007.us.bin.bak"))
        try random(512).write(to: saves.appendingPathComponent("ge007.us.bin.temp"))
        try random(64).write(to: saves.appendingPathComponent("notes.txt"))

        let mirror = GoldenPadSaveMirror(directory: saves, defaults: defaults)
        check(mirror.restore().isEmpty, "nothing to restore before anything was kept")
        check(mirror.capture() == ["ge007.us.bin", "ge007.us.bin.bak"], "keeps the save and its backup, not .temp or other files")
        check(mirror.capture().isEmpty, "an unchanged save is not stored again")

        // tvOS clears Caches: the whole GoldenPadRecomp folder disappears.
        try fm.removeItem(at: root.appendingPathComponent("GoldenPadRecomp"))
        let afterPurge = GoldenPadSaveMirror(directory: saves, defaults: defaults) // (as on next launch)
        check(afterPurge.restore() == ["ge007.us.bin", "ge007.us.bin.bak"], "restores both files after Caches was cleared")
        check((try? Data(contentsOf: saves.appendingPathComponent("ge007.us.bin"))) == save, "restored save has the same bytes")
        check((try? Data(contentsOf: saves.appendingPathComponent("ge007.us.bin.bak"))) == backup, "restored backup has the same bytes")
        check(!fm.fileExists(atPath: saves.appendingPathComponent("ge007.us.bin.temp").path), "the .temp file is not recreated")
        check(afterPurge.restore().isEmpty, "a second restore changes nothing")

        // The game saves again: disk wins, the mirror follows.
        let newer = random(512)
        try newer.write(to: saves.appendingPathComponent("ge007.us.bin"), options: .atomic)
        check(afterPurge.restore().isEmpty, "restore never overwrites a save that is on disk")
        check((try? Data(contentsOf: saves.appendingPathComponent("ge007.us.bin"))) == newer, "the newer save on disk is untouched")
        check(afterPurge.capture() == ["ge007.us.bin"], "the newer save is kept")
        try fm.removeItem(at: saves.appendingPathComponent("ge007.us.bin"))
        afterPurge.restore()
        check((try? Data(contentsOf: saves.appendingPathComponent("ge007.us.bin"))) == newer, "a later purge brings back the newer save, not the old one")

        // An empty file (an interrupted write) counts as missing.
        try Data().write(to: saves.appendingPathComponent("ge007.us.bin"))
        check(afterPurge.restore() == ["ge007.us.bin"], "an empty save file is refilled")

        // Oversized files are never put in UserDefaults.
        try random(GoldenPadSaveMirror.maxFileBytes + 1).write(to: saves.appendingPathComponent("huge.bin"))
        check(!afterPurge.capture().contains("huge.bin"), "a file over the size cap is skipped")

        // Background watching picks up a new save without being asked.
        let watched = random(512)
        afterPurge.startWatching(every: 0.2)
        try watched.write(to: saves.appendingPathComponent("ge007.us.bin"), options: .atomic)
        Thread.sleep(forTimeInterval: 2)
        afterPurge.stopWatching()
        check(defaults.data(forKey: GoldenPadSaveMirror.keyPrefix + "ge007.us.bin") == watched, "the watcher kept the new save on its own")

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("PASS: Apple TV saves survive a cleared Caches folder")
    }
}
