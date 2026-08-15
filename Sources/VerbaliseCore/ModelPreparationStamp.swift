import Foundation

/// Remembers which model folders have already survived a first load.
///
/// The first time CoreML loads a newly downloaded model it compiles it for
/// the Neural Engine — ANECompilerService at full CPU for minutes on the
/// larger tiers — and caches the result, so every later load takes seconds.
/// Nothing distinguishes the two ahead of time, which is how "loads take a
/// few seconds" became an assumption the whole loading UI was built on: every
/// measurement behind it happened to hit the warm cache (#8).
///
/// This is the app's proxy for that cache. After a load completes, the model
/// folder's fingerprint is recorded; a load whose folder doesn't match a
/// recorded fingerprint should be treated as a first-use compile and given
/// UI honest about the wait. Re-downloading a model rewrites its files, which
/// is exactly what invalidates the ANE cache — and exactly what changes the
/// fingerprint.
///
/// The proxy is deliberately conservative in one direction: macOS may still
/// evict its compile cache behind a matching stamp (an OS update, storage
/// pressure), and then a "fast" load runs long. The stamp cannot see that.
/// What it does guarantee is that the reproducible case — fresh download,
/// first load — is never again presented as a few-second wait.
public enum ModelPreparationStamp {

    private static let key = "ModelPrepared"

    /// Variant name → fingerprint at the last completed load.
    private static func recorded(in defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    public static func isPrepared(
        variant: String, folder: URL, defaults: UserDefaults = .standard
    ) -> Bool {
        guard let fingerprint = fingerprint(of: folder) else { return false }
        return recorded(in: defaults)[variant] == fingerprint
    }

    public static func recordPrepared(
        variant: String, folder: URL, defaults: UserDefaults = .standard
    ) {
        guard let fingerprint = fingerprint(of: folder) else { return }
        var seen = recorded(in: defaults)
        seen[variant] = fingerprint
        defaults.set(seen, forKey: key)
    }

    /// A cheap identity for the folder's contents: every file's relative path,
    /// size and modification time, folded into one stable value.
    ///
    /// Not a content hash — reading three gigabytes to decide which status
    /// line to show would cost a noticeable slice of the wait the status line
    /// exists to explain. Relative paths rather than absolute, so the same
    /// files stamp identically wherever the folder lives: an app update moves
    /// the bundled copy without touching its contents, and must not read as a
    /// new model.
    ///
    /// Returns nil for a missing or empty folder — "unknown", which callers
    /// treat as unprepared, the direction that fails safe.
    static func fingerprint(of folder: URL) -> String? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys
        ) else { return nil }

        var entries: [String] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let relative = url.path.hasPrefix(folder.path)
                ? String(url.path.dropFirst(folder.path.count))
                : url.lastPathComponent
            let size = values.fileSize ?? 0
            let modified = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            entries.append("\(relative):\(size):\(modified)")
        }
        guard !entries.isEmpty else { return nil }

        // Sorted because enumeration order is a filesystem detail, not part of
        // the folder's identity.
        return fnv1a(entries.sorted().joined(separator: "\n"))
    }

    /// FNV-1a, hand-rolled because it must be stable across launches --
    /// `Hasher` is seeded per process, so its values cannot be stored.
    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
