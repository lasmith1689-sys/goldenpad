import Foundation
import SwiftUI

@_silgen_name("goldenpad_crash_capture_install")
private func goldenPadCrashCaptureInstall(_ logsDirectory: UnsafePointer<CChar>, _ redirectStdio: Int32)

@_silgen_name("goldenpad_crash_note")
private func goldenPadCrashNote(_ text: UnsafePointer<CChar>)

@_silgen_name("goldenpad_crash_test")
private func goldenPadCrashTest()

/// Apple TV has no way to send us its crash reports, so GoldenPad records its
/// own (Support/RecompPrototype/goldenpad_crash_capture.cpp) and, after a
/// launch that crashed or never got the game going, shows what it recorded
/// before trying again.
enum GoldenPadCrashReport {
    static var logsDirectory: URL {
        GoldenPadStorage.supportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    /// Present from just before the renderer starts until the game has run for
    /// a while or the app is backgrounded. Left behind = the launch died while
    /// starting, even with no signal (for example killed for using too much memory).
    private static var startingMarker: URL {
        logsDirectory.appendingPathComponent("tv-game-starting.marker")
    }

    /// What the previous launch recorded, when it crashed. Set by `install()`.
    private(set) static var previous: String?
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let manager = FileManager.default
        let arguments = ProcessInfo.processInfo.arguments
        try? manager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let diedWhileStarting = manager.fileExists(atPath: startingMarker.path)
        try? manager.removeItem(at: startingMarker)
        // (--keep-console: the simulator test reads the app's console)
        logsDirectory.path.withCString { goldenPadCrashCaptureInstall($0, arguments.contains("--keep-console") ? 0 : 1) }

        let crash = (try? String(contentsOf: logsDirectory.appendingPathComponent("crash-previous.txt"), encoding: .utf8)) ?? ""
        if !crash.isEmpty || diedWhileStarting {
            previous = format(crash: crash, diedWhileStarting: diedWhileStarting,
                              log: tail(logsDirectory.appendingPathComponent("stdio-previous.log"), lines: 400))
            let first = crash.split(separator: "\n").first.map(String.init)
                ?? "stopped while the game was starting, with no crash signal (likely ended for using too much memory)"
            NSLog("[GoldenPad] crash report: the previous launch %@", first)
        }
        note("app launched")
        if arguments.contains("--crash-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { goldenPadCrashTest() }
        }
    }

    static func note(_ text: String) {
        text.withCString { goldenPadCrashNote($0) }
    }

    static func gameStarting() {
        note("game surface created; starting the renderer")
        FileManager.default.createFile(atPath: startingMarker.path, contents: Data("starting\n".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { gameSettled() }
    }

    static func gameSettled() {
        try? FileManager.default.removeItem(at: startingMarker)
    }

    static func dismiss() {
        previous = nil
    }

    private static func tail(_ url: URL, lines count: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 96 * 1024 ? size - 96 * 1024 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).map(String.init))
    }

    /// Short enough to read in one photo of the TV.
    static func format(crash: String, diedWhileStarting: Bool, log: [String]) -> String {
        var lines: [String] = []
        if crash.isEmpty {
            lines.append("No crash signal: the app stopped while the game was starting (likely ended for using too much memory).")
        } else {
            var frames = 0
            for line in crash.split(separator: "\n").map(String.init) {
                if line.first?.isNumber == true {
                    frames += 1
                    if frames > 22 { continue }
                }
                lines.append(line)
            }
        }
        // The NSLog prefix ("2026-11-20 16:40:01.123 GoldenPad...[12:34] ") only costs width.
        let cleaned = log.map { line -> String in
            if let range = line.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+ \S+\[\d+:\d+\] "#, options: .regularExpression) {
                return String(line[range.upperBound...])
            }
            return line
        }
        let header = cleaned.first(where: { $0.contains("crash capture ready") })
        lines.append("--- last lines before it stopped ---")
        if let header { lines.append(header) }
        lines.append(contentsOf: cleaned.filter { $0 != header }.suffix(14))
        return lines.map { $0.count > 170 ? String($0.prefix(167)) + "..." : $0 }.joined(separator: "\n")
    }
}

/// Shown on Apple TV instead of starting the game after a launch that crashed.
struct GoldenPadCrashReportView: View {
    let report: String
    let start: (_ safeGraphics: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GoldenPad closed unexpectedly last time")
                .font(.title2.bold())
            Text("Take a photo of this screen to share it, then try starting again.")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(report)
                .font(.system(size: 15, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 40) {
                Button("Start the game") { start(false) }
                Button("Start with safe graphics") { start(true) }
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
        .onAppear { NSLog("[GoldenPad] crash report: on screen") }
    }
}
