import Foundation
import Testing
@testable import OpenWhisperCore

@Suite("Settings model and validation")
struct SettingsTests {

    @Test("Defaults match config.example.yaml")
    func defaultsMatchExampleConfig() {
        let s = Settings()
        #expect(s.transcriptionModel == .turbo)
        #expect(s.triggerKey == "shift_r")
        #expect(s.language == "en")
        #expect(s.minDuration == 0.5)
        #expect(s.maxDuration == 300)
        #expect(s.releaseDelay == 0.05)
        #expect(s.sampleRate == 16000)
        #expect(s.soundEnabled == false)
        #expect(s.overlayStyle == .translucent)
        #expect(s.vocabulary.isEmpty)
        #expect(s.phoneticCorrections.isEmpty)
        #expect(s.inputDevice == nil)

        #expect(s.advanced.trimSilenceEnabled == true)
        #expect(s.advanced.streamingTranscribeEnabled == true)
        #expect(s.advanced.modelIdleUnloadMinutes == 120)
        #expect(s.advanced.fastTypingEnabled == true)
        #expect(s.advanced.fastTypingMaxChars == 80)
        #expect(s.advanced.clipboardRestoreDelay == 1.5)
    }

    @Test("All eight Python model keys decode")
    func allModelKeysDecode() {
        let keys = ["tiny", "base", "small", "distil-medium",
                    "medium", "distil-large", "turbo", "large"]
        for key in keys {
            #expect(TranscriptionModel(rawValue: key) != nil, "\(key) should decode")
        }
        #expect(TranscriptionModel.allCases.count == keys.count)
    }

    @Test("An empty config file yields all defaults")
    func emptyConfigYieldsDefaults() throws {
        // A user who empties the file, or one written by a future version that
        // drops a key, must still get a working app rather than a decode error.
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(decoded == Settings())
    }

    @Test("A partial config keeps defaults for absent keys")
    func partialConfigKeepsDefaults() throws {
        let json = """
        {"trigger_key": "alt_r+shift_r", "sound_enabled": true,
         "advanced": {"fast_typing_max_chars": 200}}
        """
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

        #expect(s.triggerKey == "alt_r+shift_r")
        #expect(s.soundEnabled == true)
        #expect(s.advanced.fastTypingMaxChars == 200)
        // Untouched keys keep their documented defaults.
        #expect(s.transcriptionModel == .turbo)
        #expect(s.advanced.clipboardRestoreDelay == 1.5)
        #expect(s.advanced.trimSilenceEnabled == true)
    }

    @Test("Settings round-trip through JSON")
    func roundTrip() throws {
        var s = Settings()
        s.transcriptionModel = .distilLarge
        s.triggerKey = "ctrl_r"
        s.vocabulary = ["FNOL", "Kubernetes"]
        s.phoneticCorrections = ["ethanol": "FNOL"]
        s.inputDevice = "MacBook Pro Microphone"
        s.overlayStyle = .solid

        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(Settings.self, from: data) == s)
    }

    @Test("Encoded keys use the Python config names")
    func encodedKeysMatchPython() throws {
        let data = try JSONEncoder().encode(Settings())
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // These are the names a user edits by hand and that the Python app
        // wrote; renaming any of them silently breaks an existing config.
        for key in ["transcription_model", "trigger_key", "min_duration",
                    "max_duration", "release_delay", "sample_rate",
                    "sound_enabled", "overlay_style", "phonetic_corrections",
                    "advanced"] {
            #expect(object[key] != nil, "missing key \(key)")
        }
    }

    // MARK: - Validation

    @Test("Default settings validate cleanly")
    func defaultsAreValid() {
        let result = Settings().validate()
        #expect(result.isValid)
        #expect(result.errors.isEmpty)
    }

    @Test("An invalid trigger key is an error naming the bad part")
    func invalidTriggerKey() {
        var s = Settings()
        s.triggerKey = "shift_middle"
        let result = s.validate()

        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("shift_middle") })
        // The message must list what the user can actually use.
        #expect(result.errors.contains { $0.contains("shift_r") })
    }

    @Test("A combo with one bad part reports only that part")
    func partiallyInvalidCombo() {
        var s = Settings()
        s.triggerKey = "alt_r+nope"
        let result = s.validate()
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("nope") })
    }

    @Test("Out-of-range numbers are errors")
    func outOfRangeNumbers() {
        var s = Settings()
        s.minDuration = -1
        s.sampleRate = 0
        s.advanced.clipboardRestoreDelay = -0.5
        let result = s.validate()

        #expect(result.errors.count >= 3)
        #expect(result.errors.contains { $0.contains("min_duration") })
        #expect(result.errors.contains { $0.contains("sample_rate") })
        #expect(result.errors.contains { $0.contains("clipboard_restore_delay") })
    }

    @Test("max_duration below min_duration is an error")
    func maxBelowMin() {
        var s = Settings()
        s.minDuration = 10
        s.maxDuration = 5
        #expect(s.validate().errors.contains { $0.contains("max_duration") })
    }

    @Test("Zero is allowed where it means 'never'")
    func zeroMeansNever() {
        // 0 is documented as "keep the model loaded forever" and "never
        // restore the clipboard" -- both valid, not errors.
        var s = Settings()
        s.advanced.modelIdleUnloadMinutes = 0
        s.advanced.clipboardRestoreDelay = 0
        #expect(s.validate().isValid)
    }

    // MARK: - Derived values

    @Test("Distil models force English regardless of configured language")
    func distilModelsForceEnglish() {
        var s = Settings()
        s.language = "fr"

        s.transcriptionModel = .distilLarge
        #expect(s.effectiveLanguage == "en")
        s.transcriptionModel = .distilMedium
        #expect(s.effectiveLanguage == "en")

        s.transcriptionModel = .turbo
        #expect(s.effectiveLanguage == "fr")
    }

    @Test("Phonetic corrections are exposed in a deterministic order")
    func phoneticCorrectionsDeterministic() {
        var s = Settings()
        s.phoneticCorrections = ["zebra": "Z", "alpha": "A", "mike": "M"]

        let ordered = s.orderedPhoneticCorrections
        #expect(ordered.map(\.misheard) == ["alpha", "mike", "zebra"])
        // Repeated reads must agree; a Dictionary's own order does not.
        #expect(s.orderedPhoneticCorrections.map(\.misheard) == ordered.map(\.misheard))
    }

    @Test("Trigger combo parses from the config string")
    func triggerComboParses() {
        var s = Settings()
        s.triggerKey = "alt_r+shift_r"
        #expect(s.triggerCombo?.keys == [.altR, .shiftR])

        s.triggerKey = "bogus"
        #expect(s.triggerCombo == nil)
    }
}
