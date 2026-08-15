import Foundation

/// Reads and writes the user-editable config file.
///
/// Lives in the app container's Application Support, which under the sandbox is
/// where `.applicationSupportDirectory` already resolves — no special-casing,
/// and nothing written outside the container (App Store rule 2.5.2).
public struct SettingsStore: Sendable {

    public struct LoadResult: Sendable {
        public var settings: Settings
        public var validation: ValidationResult
        /// True when the file was missing and defaults were written out.
        public var createdDefaults: Bool
    }

    public let url: URL

    public init?(url: URL? = nil) {
        if let url {
            self.url = url
            return
        }
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        self.url = support.appendingPathComponent("config.json")
    }

    /// Loads, falling back to defaults rather than failing.
    ///
    /// An unreadable or invalid config must never stop the app starting: a
    /// dictation tool that refuses to launch because of a stray comma is worse
    /// than one running on defaults while it tells you what is wrong. Invalid
    /// values are reported through `validation` for the menu to surface as a
    /// configError, exactly as the Python does.
    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let defaults = Settings()
            try? save(defaults)
            return LoadResult(settings: defaults, validation: .init(), createdDefaults: true)
        }

        do {
            let data = try Data(contentsOf: url)
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            let validation = settings.validate()

            if !validation.isValid {
                // Reject wholesale and keep the defaults, matching the Python's
                // reload behaviour: a half-applied config is harder to reason
                // about than one that was cleanly refused.
                log("config: invalid — \(validation.errors.joined(separator: "; "))")
                return LoadResult(
                    settings: Settings(), validation: validation, createdDefaults: false
                )
            }
            return LoadResult(settings: settings, validation: validation, createdDefaults: false)
        } catch {
            log("config: could not read \(url.lastPathComponent) — \(error)")
            var validation = ValidationResult()
            validation.errors.append("Could not read config.json: \(error.localizedDescription)")
            return LoadResult(
                settings: Settings(), validation: validation, createdDefaults: false
            )
        }
    }

    public func save(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        // Sorted and pretty-printed because a human edits this file, and a
        // stable key order keeps diffs meaningful.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
