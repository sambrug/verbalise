import Testing
@testable import OpenWhisperCore

@Suite("WhisperKit model mapping")
struct WhisperKitModelMapTests {

    @Test("Every key except distil-medium maps to a published model")
    func mappingCoverage() {
        // Verified against the live listing of argmaxinc/whisperkit-coreml.
        // distil-medium.en is genuinely not published, which plan §7
        // anticipated as the one greyed-out entry.
        for model in TranscriptionModel.allCases where model != .distilMedium {
            #expect(model.whisperKitModelName != nil, "\(model.rawValue) should map")
        }
        #expect(TranscriptionModel.distilMedium.whisperKitModelName == nil)
    }

    @Test("Unavailable models stay in the menu with a reason")
    func unavailableModelsExplained() {
        // The failure mode this prevents: a config naming distil-medium
        // silently falling back to another model, leaving the user wondering
        // why transcription changed.
        #expect(TranscriptionModel.distilMedium.isAvailable == false)
        #expect(TranscriptionModel.distilMedium.unavailableReason != nil)

        #expect(TranscriptionModel.turbo.isAvailable)
        #expect(TranscriptionModel.turbo.unavailableReason == nil)
    }

    @Test("availableCases excludes exactly the unavailable ones")
    func availableCasesFiltered() {
        let available = TranscriptionModel.availableCases
        #expect(available.count == TranscriptionModel.allCases.count - 1)
        #expect(!available.contains(.distilMedium))
        #expect(available.contains(.turbo))
    }

    @Test("Model names carry no path separators or whitespace")
    func namesAreWellFormed() {
        // They are used as a path component under the container.
        for model in TranscriptionModel.availableCases {
            let name = try! #require(model.whisperKitModelName)
            #expect(!name.contains("/"), "\(name) must not contain a separator")
            #expect(!name.contains(" "), "\(name) must not contain whitespace")
            #expect(!name.isEmpty)
        }
    }

    @Test("The default model is available")
    func defaultModelIsAvailable() {
        // A default that cannot load would make a fresh install dead on arrival.
        #expect(Settings().transcriptionModel.isAvailable)
    }
}
