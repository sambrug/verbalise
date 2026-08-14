import Foundation

/// Speech model choice, as three tiers rather than the Python's eight keys
/// (daemon.py:51).
///
/// A deliberate divergence from plan §4, which asked for the eight keys
/// preserved. Those eight existed because MLX published that many; WhisperKit's
/// CoreML builds do not line up with them one-for-one, and several would have
/// been near-duplicates or unavailable — `distil-medium.en` is not published at
/// all. Three tiers the user can reason about beat eight where two are broken.
///
/// `balanced` is the default and the one shipped inside the app bundle; the
/// other two download on demand, so the package carries one model rather than
/// three.
public enum TranscriptionModel: String, CaseIterable, Codable, Sendable {
    case fast
    case balanced
    case accurate

    public var displayName: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .accurate: "Accurate"
        }
    }

    /// Roughly what the download costs. The two smaller tiers state their size
    /// in the WhisperKit repo's own filename; `large-v3` does not, and 3 GB is
    /// what it measured on disk.
    public var approximateDownloadBytes: Int64 {
        switch self {
        case .fast: 216_000_000
        case .balanced: 954_000_000
        case .accurate: 3_000_000_000
        }
    }

    /// Shown next to the name so the download cost is visible before choosing.
    public var approximateDownloadSize: String {
        ModelCatalog.sizeText(approximateDownloadBytes)
    }

    /// The underlying model, for the row that already says what the tier is
    /// for.
    ///
    /// Named in full. An earlier version dropped "Whisper" as redundant --
    /// the same word on all three lines, distinguishing nothing -- which was
    /// true of the list read as a list and wrong for the reader it is there
    /// for. "Small" alone says nothing to someone who does not already know
    /// what is under the app; "Whisper Small" tells them what to search for.
    public var variantName: String {
        switch self {
        case .fast: "Whisper Small"
        case .balanced: "Whisper Large v3 Turbo"
        case .accurate: "Whisper Large v3"
        }
    }

    /// One clause, same shape for every tier, naming the trade being made.
    ///
    /// The three are written to be read against each other -- a user picking
    /// between them is comparing, so parallel phrasing does the comparing for
    /// them. An earlier version described `balanced` as "Included with the app",
    /// which answered a question nobody was asking and left the tier that most
    /// people should choose as the only one not saying how it performs.
    public var summary: String {
        switch self {
        case .fast: "Quickest, least accurate"
        case .balanced: "Balance of speed and accuracy"
        case .accurate: "Most accurate, slowest"
        }
    }

    /// The model that ships inside the bundle.
    public static let bundled: TranscriptionModel = .balanced

    /// Accepts the Python app's eight key names as aliases.
    ///
    /// An existing config naming `turbo` or `tiny` must keep working rather
    /// than failing validation and dumping the user back to defaults, so the
    /// old names map onto the nearest tier.
    static func fromLegacyName(_ raw: String) -> TranscriptionModel? {
        switch raw {
        case "tiny", "base", "small": .fast
        case "medium", "distil-medium", "distil-large", "turbo": .balanced
        case "large": .accurate
        default: nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let model = TranscriptionModel(rawValue: raw)
                ?? TranscriptionModel.fromLegacyName(raw)
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown transcription_model '\(raw)'"
            ))
        }
        self = model
    }
}

/// Whether the floating pill is shown.
///
/// The Python offered three styles; the opaque `solid` capsule existed as a
/// fallback for macOS versions without Liquid Glass, and with a macOS 14 floor
/// and Tahoe's glass available it is just a worse-looking duplicate. Two states
/// is the honest set.
///
/// Old configs naming `translucent` or `solid` still load, both meaning on —
/// neither should leave a user with no pill and no explanation.
public enum OverlayStyle: String, CaseIterable, Codable, Sendable {
    case on
    case off

    public var displayName: String {
        self == .on ? "On" : "Off"
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "on", "translucent", "solid": self = .on
        case "off": self = .off
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown overlay_style '\(raw)'"
            ))
        }
    }
}

/// The `advanced:` block of config.example.yaml.
public struct AdvancedSettings: Codable, Equatable, Sendable {
    public var trimSilenceEnabled: Bool = true
    public var streamingTranscribeEnabled: Bool = true
    public var modelIdleUnloadMinutes: Int = 120
    public var fastTypingEnabled: Bool = true
    public var fastTypingMaxChars: Int = 80
    public var clipboardRestoreDelay: Double = 1.5

    public init() {}

    enum CodingKeys: String, CodingKey {
        case trimSilenceEnabled = "trim_silence_enabled"
        case streamingTranscribeEnabled = "streaming_transcribe_enabled"
        case modelIdleUnloadMinutes = "model_idle_unload_minutes"
        case fastTypingEnabled = "fast_typing_enabled"
        case fastTypingMaxChars = "fast_typing_max_chars"
        case clipboardRestoreDelay = "clipboard_restore_delay"
    }

    /// Every key is optional on read so a partial config file -- or one written
    /// by an older version -- keeps its documented default rather than failing
    /// to decode and taking the whole config down with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        trimSilenceEnabled = try c.decodeIfPresent(Bool.self, forKey: .trimSilenceEnabled) ?? trimSilenceEnabled
        streamingTranscribeEnabled = try c.decodeIfPresent(Bool.self, forKey: .streamingTranscribeEnabled) ?? streamingTranscribeEnabled
        modelIdleUnloadMinutes = try c.decodeIfPresent(Int.self, forKey: .modelIdleUnloadMinutes) ?? modelIdleUnloadMinutes
        fastTypingEnabled = try c.decodeIfPresent(Bool.self, forKey: .fastTypingEnabled) ?? fastTypingEnabled
        fastTypingMaxChars = try c.decodeIfPresent(Int.self, forKey: .fastTypingMaxChars) ?? fastTypingMaxChars
        clipboardRestoreDelay = try c.decodeIfPresent(Double.self, forKey: .clipboardRestoreDelay) ?? clipboardRestoreDelay
    }
}

/// Mirrors config.example.yaml exactly: same keys, same defaults.
///
/// Persisted as JSON rather than YAML (plan §10 permits the format change;
/// keys and defaults do not change). JSON avoids pulling a YAML parser into
/// the app for a file this small, and stays hand-editable, which is what
/// "Open Config" relies on.
public struct Settings: Codable, Equatable, Sendable {
    public var transcriptionModel: TranscriptionModel = .bundled
    public var triggerKey: String = "shift_r"
    public var language: String = "en"
    public var minDuration: Double = 0.5
    public var maxDuration: Double = 300
    public var releaseDelay: Double = 0.05
    public var sampleRate: Int = 16000
    public var soundEnabled: Bool = false
    public var overlayStyle: OverlayStyle = .on
    public var vocabulary: [String] = []
    public var phoneticCorrections: [String: String] = [:]
    public var inputDevice: String?
    public var advanced: AdvancedSettings = .init()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case transcriptionModel = "transcription_model"
        case triggerKey = "trigger_key"
        case language
        case minDuration = "min_duration"
        case maxDuration = "max_duration"
        case releaseDelay = "release_delay"
        case sampleRate = "sample_rate"
        case soundEnabled = "sound_enabled"
        case overlayStyle = "overlay_style"
        case vocabulary
        case phoneticCorrections = "phonetic_corrections"
        case inputDevice = "input_device"
        case advanced
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        transcriptionModel = try c.decodeIfPresent(TranscriptionModel.self, forKey: .transcriptionModel) ?? transcriptionModel
        triggerKey = try c.decodeIfPresent(String.self, forKey: .triggerKey) ?? triggerKey
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        minDuration = try c.decodeIfPresent(Double.self, forKey: .minDuration) ?? minDuration
        maxDuration = try c.decodeIfPresent(Double.self, forKey: .maxDuration) ?? maxDuration
        releaseDelay = try c.decodeIfPresent(Double.self, forKey: .releaseDelay) ?? releaseDelay
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? sampleRate
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? soundEnabled
        overlayStyle = try c.decodeIfPresent(OverlayStyle.self, forKey: .overlayStyle) ?? overlayStyle
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? vocabulary
        phoneticCorrections = try c.decodeIfPresent([String: String].self, forKey: .phoneticCorrections) ?? phoneticCorrections
        inputDevice = try c.decodeIfPresent(String.self, forKey: .inputDevice)
        advanced = try c.decodeIfPresent(AdvancedSettings.self, forKey: .advanced) ?? advanced
    }

    /// Parsed trigger, or nil when `triggerKey` is malformed.
    public var triggerCombo: TriggerCombo? {
        TriggerCombo(configValue: triggerKey)
    }

    /// Phonetic corrections as an ordered list for `TextPipeline`.
    ///
    /// Sorted by key rather than left in file order. Python applies them in
    /// dict-insertion order, which a Swift Dictionary cannot preserve through
    /// decoding; sorting makes the result deterministic instead of dependent on
    /// hash order, which would be worse than either. Only observable when two
    /// rules overlap.
    public var orderedPhoneticCorrections: [(misheard: String, correct: String)] {
        phoneticCorrections
            .sorted { $0.key < $1.key }
            .map { (misheard: $0.key, correct: $0.value) }
    }

    /// The language to request, or nil to let Whisper detect it.
    ///
    /// The Python forced `en` for its distil models, which were English-only
    /// (daemon.py:1078). None of the three tiers here is English-only, so that
    /// clamp no longer applies and the configured language is always honoured.
    ///
    /// Optional because "Automatic" is a real choice rather than a missing
    /// one: WhisperKit detects the language when given no code, which is what
    /// a bilingual user wants and what a single-language user should not pay
    /// for.
    public var effectiveLanguage: String? {
        language == Language.automaticCode ? nil : language
    }
}

// MARK: - Validation

public struct ValidationResult: Equatable, Sendable {
    public var errors: [String] = []
    public var warnings: [String] = []
    public var isValid: Bool { errors.isEmpty }
}

extension Settings {
    /// Ported from `validate_config` (daemon.py:506), with the same messages so
    /// a user who has seen the Python app's error recognises this one.
    ///
    /// Type-level checks the Python needs (`isinstance(..., int)`) are enforced
    /// by decoding here, so this covers only the range and vocabulary checks
    /// that types cannot express.
    public func validate() -> ValidationResult {
        var result = ValidationResult()

        if triggerCombo == nil {
            let parts = triggerKey.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            let invalid = parts.filter { TriggerKey(rawValue: $0) == nil }
            let valid = TriggerKey.allCases.map(\.rawValue).joined(separator: ", ")
            result.errors.append(
                "trigger_key '\(triggerKey)' contains invalid key(s): \(invalid.joined(separator: ", ")). Valid keys: \(valid)"
            )
        }

        if minDuration < 0 {
            result.errors.append("min_duration must be a positive number, got \(minDuration)")
        }
        if sampleRate <= 0 {
            result.errors.append("sample_rate must be a positive integer, got \(sampleRate)")
        }
        if maxDuration <= minDuration {
            result.errors.append("max_duration must be greater than min_duration, got \(maxDuration)")
        }
        if advanced.modelIdleUnloadMinutes < 0 {
            result.errors.append("model_idle_unload_minutes must be 0 or greater, got \(advanced.modelIdleUnloadMinutes)")
        }
        if advanced.fastTypingMaxChars < 0 {
            result.errors.append("fast_typing_max_chars must be 0 or greater, got \(advanced.fastTypingMaxChars)")
        }
        if advanced.clipboardRestoreDelay < 0 {
            result.errors.append("clipboard_restore_delay must be 0 or greater, got \(advanced.clipboardRestoreDelay)")
        }

        // Warnings: valid, but probably not what the user meant.
        if releaseDelay > 1 {
            result.warnings.append("release_delay of \(releaseDelay)s is unusually long; text will feel slow to appear")
        }
        if phoneticCorrections.keys.contains(where: { $0.isEmpty }) {
            result.warnings.append("phonetic_corrections contains an empty key, which will be ignored")
        }

        return result
    }
}
