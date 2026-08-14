import Foundation

/// Speech model keys. The eight from the Python registry (daemon.py:51), kept
/// as the wire format so existing configs load unchanged. The mapping to
/// WhisperKit model names is resolved in Phase 4 (plan §7); the *key* is what
/// the config and menu speak.
public enum TranscriptionModel: String, CaseIterable, Codable, Sendable {
    case tiny, base, small
    case distilMedium = "distil-medium"
    case medium
    case distilLarge = "distil-large"
    case turbo, large

    /// Distil models are English-only; the Python app forces `language: en`
    /// for them (daemon.py:1078).
    public var isEnglishOnly: Bool {
        self == .distilMedium || self == .distilLarge
    }

    public var displayName: String {
        switch self {
        case .tiny: "Tiny"
        case .base: "Base"
        case .small: "Small"
        case .distilMedium: "Distil Medium (English)"
        case .medium: "Medium"
        case .distilLarge: "Distil Large (English)"
        case .turbo: "Turbo"
        case .large: "Large"
        }
    }
}

public enum OverlayStyle: String, CaseIterable, Codable, Sendable {
    case translucent, solid, off
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
    public var transcriptionModel: TranscriptionModel = .turbo
    public var triggerKey: String = "shift_r"
    public var language: String = "en"
    public var minDuration: Double = 0.5
    public var maxDuration: Double = 300
    public var releaseDelay: Double = 0.05
    public var sampleRate: Int = 16000
    public var soundEnabled: Bool = false
    public var overlayStyle: OverlayStyle = .translucent
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

    /// The language to actually request, honouring the distil models'
    /// English-only constraint (daemon.py:1078).
    public var effectiveLanguage: String {
        transcriptionModel.isEnglishOnly ? "en" : language
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
