import Foundation
import Testing
@testable import OpenWhisperCore

@Suite("Import from the Python app")
struct PythonImportTests {

    /// The real config.example.yaml, near enough — comments, inline comments,
    /// an advanced block, and the two collections that are skipped.
    static let sampleConfig = """
    # Open Whisper configuration.
    transcription_model: turbo
    trigger_key: alt_r+shift_r
    language: fr
    min_duration: 0.7
    max_duration: 240
    release_delay: 0.05
    sample_rate: 16000

    sound_enabled: true
    overlay_style: solid
    vocabulary: []
    phonetic_corrections: {}
    input_device: null

    advanced:
      trim_silence_enabled: false
      streaming_transcribe_enabled: true
      model_idle_unload_minutes: 30
      fast_typing_enabled: false
      fast_typing_max_chars: 120
      clipboard_restore_delay: 2.5
    """

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Config

    @Test("Flat scalar keys are imported")
    func scalarKeysImported() {
        let (s, _) = PythonImport.mergeConfig(Self.sampleConfig, into: Settings())

        #expect(s.triggerKey == "alt_r+shift_r")
        #expect(s.language == "fr")
        #expect(s.minDuration == 0.7)
        #expect(s.maxDuration == 240)
        #expect(s.sampleRate == 16000)
        #expect(s.soundEnabled == true)
        #expect(s.inputDevice == nil, "null must mean nil, not the string 'null'")
    }

    @Test("The advanced block is imported without leaking into top level")
    func advancedBlockImported() {
        let (s, _) = PythonImport.mergeConfig(Self.sampleConfig, into: Settings())

        #expect(s.advanced.trimSilenceEnabled == false)
        #expect(s.advanced.streamingTranscribeEnabled == true)
        #expect(s.advanced.modelIdleUnloadMinutes == 30)
        #expect(s.advanced.fastTypingEnabled == false)
        #expect(s.advanced.fastTypingMaxChars == 120)
        #expect(s.advanced.clipboardRestoreDelay == 2.5)
    }

    @Test("Legacy model and overlay names map to the current ones")
    func legacyNamesMapped() {
        let (s, _) = PythonImport.mergeConfig(Self.sampleConfig, into: Settings())
        #expect(s.transcriptionModel == .balanced, "turbo maps to balanced")
        #expect(s.overlayStyle == .on, "solid means the pill is on")
    }

    @Test("Comments and inline comments are ignored")
    func commentsIgnored() {
        let yaml = """
        # leading comment
        language: de   # trailing comment
        sample_rate: 22050  # another
        """
        let (s, _) = PythonImport.mergeConfig(yaml, into: Settings())
        #expect(s.language == "de")
        #expect(s.sampleRate == 22050)
    }

    @Test("Skipped collections are reported rather than silently dropped")
    func skippedCollectionsReported() {
        // Vocabulary and phonetic corrections are the two settings a user is
        // most likely to have customised. Half-importing them would be worse
        // than saying they were not imported.
        let yaml = """
        vocabulary:
          - FNOL
          - Kubernetes
        phonetic_corrections:
          ethanol: FNOL
        """
        let (_, notes) = PythonImport.mergeConfig(yaml, into: Settings())
        #expect(notes.contains { $0.contains("Vocabulary") })
    }

    @Test("Empty collections produce no note")
    func emptyCollectionsSilent() {
        // "[]" and "{}" are the defaults and carry nothing worth warning about.
        let (_, notes) = PythonImport.mergeConfig(
            "vocabulary: []\nphonetic_corrections: {}", into: Settings()
        )
        #expect(notes.isEmpty)
    }

    @Test("Unknown values are reported and leave the setting unchanged")
    func unknownValuesReported() {
        let yaml = "trigger_key: shift_middle\ntranscription_model: enormous"
        let (s, notes) = PythonImport.mergeConfig(yaml, into: Settings())

        #expect(s.triggerKey == "shift_r", "must keep the existing value")
        #expect(s.transcriptionModel == .balanced)
        #expect(notes.count == 2)
    }

    @Test("Unrecognised keys are skipped without disturbing anything")
    func unknownKeysSkipped() {
        // A config from a newer or older Python version may carry keys this
        // does not know; they must not derail the rest of the import.
        let yaml = "some_future_key: 42\nlanguage: es"
        let (s, _) = PythonImport.mergeConfig(yaml, into: Settings())
        #expect(s.language == "es")
    }

    @Test("An empty config changes nothing")
    func emptyConfigNoChange() {
        let (s, _) = PythonImport.mergeConfig("", into: Settings())
        #expect(s == Settings())
    }

    // MARK: - Directory read

    @Test("Stats and recent transcripts are read from a folder")
    func readsStatsAndRecent() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(#"{"total_words": 4321, "total_recordings": 99}"#.utf8)
            .write(to: dir.appendingPathComponent("api-usage.json"))
        try Data(#"[{"text":"hello","ts":"2026-01-01T09:00:00"}]"#.utf8)
            .write(to: dir.appendingPathComponent("recent-transcripts.json"))
        try Data(Self.sampleConfig.utf8)
            .write(to: dir.appendingPathComponent("config.yaml"))

        let result = PythonImport.read(from: dir)

        #expect(result.stats?.totalWords == 4321)
        #expect(result.stats?.totalRecordings == 99)
        #expect(result.recent?.first?.text == "hello")
        #expect(result.settings?.language == "fr")
        #expect(result.importedSomething)
    }

    @Test("Each file is optional")
    func filesAreIndependent() throws {
        // Stats without a config, or the reverse, is a normal state — neither
        // should abort the import.
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"total_words": 10, "total_recordings": 2}"#.utf8)
            .write(to: dir.appendingPathComponent("api-usage.json"))

        let result = PythonImport.read(from: dir)
        #expect(result.stats?.totalWords == 10)
        #expect(result.settings == nil)
        #expect(result.importedSomething)
    }

    @Test("An unrelated folder says so rather than reporting success")
    func wrongFolderExplains() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = PythonImport.read(from: dir)
        #expect(!result.importedSomething)
        #expect(result.notes.contains { $0.contains("No Open Whisper data") })
    }

    @Test("A corrupt file is reported, not treated as absent")
    func corruptFileReported() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent("api-usage.json"))

        let result = PythonImport.read(from: dir)
        #expect(result.stats == nil)
        #expect(result.notes.contains { $0.contains("api-usage.json") })
    }
}
