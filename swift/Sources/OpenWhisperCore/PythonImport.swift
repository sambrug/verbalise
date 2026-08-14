import Foundation

/// Brings settings and lifetime stats across from the Python app (plan §9
/// phase 6).
///
/// The user picks the folder themselves through an open panel, which is what
/// makes reading outside the container sandbox-legal — the grant comes from the
/// selection, not from an entitlement.
public enum PythonImport {

    public struct Result: Sendable {
        public var stats: UsageStats?
        public var recent: [RecentTranscript]?
        public var settings: Settings?
        /// Things found but deliberately not imported, to tell the user about
        /// rather than let them discover later.
        public var notes: [String] = []

        public var importedSomething: Bool {
            stats != nil || recent != nil || settings != nil
        }
    }

    /// Reads whatever is present. Every file is optional: a user may have
    /// stats without a config, or a config they never let the app write stats
    /// for, and neither should abort the import.
    public static func read(from directory: URL, into current: Settings = Settings()) -> Result {
        var result = Result()

        let statsURL = directory.appendingPathComponent("api-usage.json")
        if let data = try? Data(contentsOf: statsURL) {
            if let decoded = try? JSONDecoder().decode(UsageStats.self, from: data) {
                result.stats = decoded
            } else {
                result.notes.append("api-usage.json could not be read.")
            }
        }

        let recentURL = directory.appendingPathComponent("recent-transcripts.json")
        if let data = try? Data(contentsOf: recentURL) {
            if let decoded = try? JSONDecoder().decode([RecentTranscript].self, from: data) {
                result.recent = decoded
            } else {
                result.notes.append("recent-transcripts.json could not be read.")
            }
        }

        let configURL = directory.appendingPathComponent("config.yaml")
        if let text = try? String(contentsOf: configURL, encoding: .utf8) {
            let (settings, notes) = mergeConfig(text, into: current)
            result.settings = settings
            result.notes.append(contentsOf: notes)
        }

        if !result.importedSomething {
            result.notes.append(
                "No Open Whisper data found there. Look for a folder containing "
                + "config.yaml or api-usage.json."
            )
        }
        return result
    }

    // MARK: - Config

    /// Reads the flat scalar keys out of the Python's YAML config.
    ///
    /// Deliberately **not** a YAML parser. config.yaml is a known, flat file of
    /// `key: value` pairs plus one nested `advanced:` block, and hand-rolling
    /// general YAML to read it would be far more code and far more ways to be
    /// subtly wrong. Anything this does not recognise is skipped and reported,
    /// never guessed at.
    ///
    /// `vocabulary` and `phonetic_corrections` are skipped on purpose: they are
    /// block collections, they are the two settings a user is most likely to
    /// have customised, and silently importing half a list would be worse than
    /// asking them to paste it into the editor.
    static func mergeConfig(_ yaml: String, into base: Settings) -> (Settings, [String]) {
        var settings = base
        var notes: [String] = []
        var inAdvanced = false
        var sawSkippedCollection = false
        /// Set while inside a `vocabulary:` or `phonetic_corrections:` block,
        /// so its indented entries are consumed rather than mistaken for
        /// settings — and so an *empty* block does not raise a false warning.
        var insideSkippedCollection = false

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t")
            if !isIndented {
                inAdvanced = false
                insideSkippedCollection = false
            } else if insideSkippedCollection {
                // An entry under vocabulary or phonetic_corrections. Its
                // presence is what proves the block is non-empty.
                sawSkippedCollection = true
                continue
            }

            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            // Strip a trailing comment, but only when it is not inside quotes.
            if !value.hasPrefix("\""), !value.hasPrefix("'"),
               let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            if key == "advanced", value.isEmpty {
                inAdvanced = true
                continue
            }

            if key == "vocabulary" || key == "phonetic_corrections" {
                if value.isEmpty {
                    // Block form: whether it holds anything is decided by
                    // whatever follows, not by this line.
                    insideSkippedCollection = true
                } else if value != "[]", value != "{}" {
                    // Inline and non-empty. "[]" and "{}" are the defaults and
                    // carry nothing worth warning about.
                    sawSkippedCollection = true
                }
                continue
            }

            if value.isEmpty { continue }

            apply(key: key, value: value, inAdvanced: inAdvanced, to: &settings, notes: &notes)
        }

        if sawSkippedCollection {
            notes.append(
                "Vocabulary and phonetic corrections were not imported — "
                + "re-enter them from Settings."
            )
        }
        return (settings, notes)
    }

    private static func apply(
        key: String,
        value: String,
        inAdvanced: Bool,
        to settings: inout Settings,
        notes: inout [String]
    ) {
        func bool(_ raw: String) -> Bool? {
            switch raw.lowercased() {
            case "true", "yes", "on": true
            case "false", "no", "off": false
            default: nil
            }
        }

        if inAdvanced {
            switch key {
            case "trim_silence_enabled": settings.advanced.trimSilenceEnabled = bool(value) ?? settings.advanced.trimSilenceEnabled
            case "streaming_transcribe_enabled": settings.advanced.streamingTranscribeEnabled = bool(value) ?? settings.advanced.streamingTranscribeEnabled
            case "model_idle_unload_minutes": settings.advanced.modelIdleUnloadMinutes = Int(value) ?? settings.advanced.modelIdleUnloadMinutes
            case "fast_typing_enabled": settings.advanced.fastTypingEnabled = bool(value) ?? settings.advanced.fastTypingEnabled
            case "fast_typing_max_chars": settings.advanced.fastTypingMaxChars = Int(value) ?? settings.advanced.fastTypingMaxChars
            case "clipboard_restore_delay": settings.advanced.clipboardRestoreDelay = Double(value) ?? settings.advanced.clipboardRestoreDelay
            default: break
            }
            return
        }

        switch key {
        case "transcription_model":
            // Goes through the same legacy mapping a config file would.
            if let model = TranscriptionModel(rawValue: value)
                ?? TranscriptionModel.fromLegacyName(value) {
                settings.transcriptionModel = model
            } else {
                notes.append("Unknown model '\(value)' — left unchanged.")
            }
        case "trigger_key":
            if TriggerCombo(configValue: value) != nil {
                settings.triggerKey = value
            } else {
                notes.append("Unknown trigger key '\(value)' — left unchanged.")
            }
        case "language": settings.language = value
        case "min_duration": settings.minDuration = Double(value) ?? settings.minDuration
        case "max_duration": settings.maxDuration = Double(value) ?? settings.maxDuration
        case "release_delay": settings.releaseDelay = Double(value) ?? settings.releaseDelay
        case "sample_rate": settings.sampleRate = Int(value) ?? settings.sampleRate
        case "sound_enabled": settings.soundEnabled = bool(value) ?? settings.soundEnabled
        case "overlay_style":
            // "solid" and "translucent" both mean on here, as elsewhere.
            settings.overlayStyle = value == "off" ? .off : .on
        case "input_device":
            settings.inputDevice = value.lowercased() == "null" ? nil : value
        default:
            break
        }
    }
}
