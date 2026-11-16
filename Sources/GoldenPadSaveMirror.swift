import Foundation

/// Apple TV apps get no guaranteed-persistent file storage: GoldenPad's runtime
/// files live in Caches there, and tvOS may delete Caches when the Apple TV runs
/// low on space. GoldenEye's save is tiny (a 512-byte EEPROM file plus its
/// backup), so it is mirrored into UserDefaults, which tvOS keeps (up to about
/// 500 KB per app), and written back before the game starts if it went missing.
///
/// The files on disk stay the source of truth: restore only fills in files that
/// are missing or empty, and capture only ever copies disk into the mirror.
final class GoldenPadSaveMirror: @unchecked Sendable {
    static let keyPrefix = "goldenpad.saveMirror."
    /// Per-file cap, far above GoldenEye's 512 bytes, so the mirror can never
    /// eat the Apple TV's UserDefaults budget.
    static let maxFileBytes = 16 * 1024

    let directory: URL
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "GoldenPad.SaveMirror")
    private var timer: DispatchSourceTimer?

    init(directory: URL, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
    }

    /// Save files the runtime writes: `<game>.bin` and its `<game>.bin.bak`
    /// backup (not the `.temp` file it writes first and renames).
    static func isMirrored(_ name: String) -> Bool {
        name.hasSuffix(".bin") || name.hasSuffix(".bin.bak")
    }

    /// Puts back any mirrored save that is missing or empty on disk.
    /// Returns the file names it wrote.
    @discardableResult
    func restore() -> [String] {
        queue.sync { restoreLocked() }
    }

    /// Copies every save whose bytes changed into the mirror.
    /// Returns the file names it stored.
    @discardableResult
    func capture() -> [String] {
        queue.sync { captureLocked() }
    }

    /// Captures every `interval` seconds until `stopWatching()`.
    func startWatching(every interval: TimeInterval = 3) {
        queue.sync {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
            source.setEventHandler { [weak self] in _ = self?.captureLocked() }
            source.resume()
            timer = source
        }
    }

    func stopWatching() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func mirroredNames() -> [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.keyPrefix) }
            .map { String($0.dropFirst(Self.keyPrefix.count)) }
            .filter { Self.isMirrored($0) && !$0.contains("/") }
            .sorted()
    }

    private func restoreLocked() -> [String] {
        var restored: [String] = []
        let manager = FileManager.default
        for name in mirroredNames() {
            guard let data = defaults.data(forKey: Self.keyPrefix + name), !data.isEmpty else { continue }
            let url = directory.appendingPathComponent(name)
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size == 0 else { continue }
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                restored.append(name)
                NSLog("[GoldenPad] saves: restored %@ (%d bytes) after the system cleared it", name, data.count)
            } catch {
                NSLog("[GoldenPad] saves: could not restore %@: %@", name, error.localizedDescription)
            }
        }
        return restored
    }

    private func captureLocked() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var stored: [String] = []
        for name in names.sorted() where Self.isMirrored(name) {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            guard data.count <= Self.maxFileBytes else {
                NSLog("[GoldenPad] saves: %@ is %d bytes, too big to keep outside Caches", name, data.count)
                continue
            }
            let key = Self.keyPrefix + name
            guard defaults.data(forKey: key) != data else { continue }
            defaults.set(data, forKey: key)
            stored.append(name)
            NSLog("[GoldenPad] saves: kept %@ (%d bytes) outside Caches", name, data.count)
        }
        return stored
    }
}
