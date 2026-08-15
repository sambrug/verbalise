import Foundation
import Testing
@testable import OpenWhisperCore

@Suite("Transcription model tiers")
struct WhisperKitModelMapTests {

    @Test("Three tiers, all mapping to published models")
    func everyTierMaps() {
        // Verified against the live listing of argmaxinc/whisperkit-coreml.
        // Collapsing the Python's eight keys to three removed the one that had
        // no CoreML build at all (distil-medium.en), so there is no longer any
        // permanently-unavailable entry to grey out.
        #expect(TranscriptionModel.allCases.count == 3)
        for model in TranscriptionModel.allCases {
            #expect(!model.whisperKitModelName.isEmpty)
        }
    }

    @Test("Model names are well formed for use as a path component")
    func namesAreWellFormed() {
        for model in TranscriptionModel.allCases {
            let name = model.whisperKitModelName
            #expect(!name.contains("/"), "\(name) must not contain a separator")
            #expect(!name.contains(" "), "\(name) must not contain whitespace")
        }
    }

    @Test("Tiers map to distinct models")
    func tiersAreDistinct() {
        let names = Set(TranscriptionModel.allCases.map(\.whisperKitModelName))
        #expect(names.count == TranscriptionModel.allCases.count)
    }

    @Test("The default is the tier bundled with the app")
    func defaultIsBundled() {
        // A default that is not bundled would make a fresh install wait on a
        // download before the first dictation.
        #expect(Settings().transcriptionModel == TranscriptionModel.bundled)
        #expect(TranscriptionModel.bundled == .balanced)
    }

    @Test("fast and balanced use compressed builds")
    func compressedBuildsChosen() {
        // The full-precision turbo is ~3GB against the compressed ~954MB. For
        // an app nobody can use until the download finishes, that difference
        // matters more than the marginal accuracy.
        #expect(TranscriptionModel.fast.whisperKitModelName.hasSuffix("MB"))
        #expect(TranscriptionModel.balanced.whisperKitModelName.hasSuffix("MB"))
        // accurate is the deliberate exception, for people who will wait.
        #expect(!TranscriptionModel.accurate.whisperKitModelName.hasSuffix("MB"))
    }

    // MARK: - Legacy config compatibility

    @Test("All eight Python key names still decode")
    func legacyKeysDecode() throws {
        // An existing config must keep working rather than failing validation
        // and silently dumping the user back to defaults.
        let expected: [String: TranscriptionModel] = [
            "tiny": .fast, "base": .fast, "small": .fast,
            "medium": .balanced, "distil-medium": .balanced,
            "distil-large": .balanced, "turbo": .balanced,
            "large": .accurate,
        ]
        for (raw, tier) in expected {
            let json = Data(#"{"transcription_model":"\#(raw)"}"#.utf8)
            let settings = try JSONDecoder().decode(Settings.self, from: json)
            #expect(settings.transcriptionModel == tier, "\(raw) should map to \(tier)")
        }
    }

    @Test("New tier names decode")
    func tierNamesDecode() throws {
        for tier in TranscriptionModel.allCases {
            let json = Data(#"{"transcription_model":"\#(tier.rawValue)"}"#.utf8)
            let settings = try JSONDecoder().decode(Settings.self, from: json)
            #expect(settings.transcriptionModel == tier)
        }
    }

    @Test("An unknown model name is rejected, not silently defaulted")
    func unknownNameRejected() {
        // Validation surfaces this as a configError; silently substituting a
        // model would leave the user wondering why accuracy changed.
        let json = Data(#"{"transcription_model":"enormous"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Settings.self, from: json)
        }
    }

    @Test("Every tier states its download size and a summary")
    func tiersAreDescribed() {
        // The menu shows these; a user choosing "accurate" should see the 3GB
        // cost before committing to it, not after.
        for model in TranscriptionModel.allCases {
            #expect(!model.displayName.isEmpty)
            #expect(!model.approximateDownloadSize.isEmpty)
            #expect(!model.summary.isEmpty)
        }
    }
}
