import Foundation
import VerbaliseCore
import WhisperKit

// Written out as `VerbaliseCore.ModelDownloader` throughout: WhisperKit
// exports a `ModelDownloader` of its own, so the bare name is ambiguous in
// any file importing both.
extension VerbaliseCore.ModelDownloader {

    /// The real download path, wired to WhisperKit and the engine's storage.
    ///
    /// Sharing the engine's storage location is what makes the two meet:
    /// whatever this fetches, the engine later finds already on disk.
    public static func live(
        onChange: @escaping @Sendable ([TranscriptionModel: Double?]) -> Void = { _ in }
    ) -> VerbaliseCore.ModelDownloader {
        VerbaliseCore.ModelDownloader(
            isDownloaded: { TranscriptionEngine.isDownloaded($0) },
            download: { model, report in
                let variant = model.whisperKitModelName
                _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: TranscriptionEngine.modelStorage,
                    progressCallback: { progress in report(progress.fractionCompleted) }
                )
                log("model: \(variant) downloaded")
            },
            removePartial: { TranscriptionEngine.removeDownload($0) },
            onChange: onChange
        )
    }
}
