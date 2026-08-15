import Foundation
import VerbaliseCore
import WhisperKit

/// The files a compile expects on disk went missing between steps — the model
/// was removed, or a download turned out to be incomplete. Rare, but the
/// message ends up in front of the user, so it says what to do about it.
struct ModelFilesMissingError: LocalizedError {
    let model: TranscriptionModel
    var errorDescription: String? {
        "\(model.displayName)'s files aren't on disk. Download it again."
    }
}

extension ModelPreparer {

    /// The real compile queue, wired to WhisperKit and the preparation stamp.
    ///
    /// `prewarm` without `load` walks every model component through CoreML —
    /// which is what populates macOS's compile cache — and drops each one as
    /// it goes, so compiling a three-gigabyte tier does not hold three
    /// gigabytes alongside whatever dictation is using. The stamp is the
    /// durable output, the same one the engine checks before promising a fast
    /// load.
    public static func live(
        onChange: @escaping @Sendable (Set<TranscriptionModel>) -> Void = { _ in }
    ) -> ModelPreparer {
        ModelPreparer(
            isPrepared: { TranscriptionEngine.isPrepared($0) },
            compile: { model in
                let variant = model.whisperKitModelName
                guard let folder = TranscriptionEngine.existingFolder(for: variant) else {
                    throw ModelFilesMissingError(model: model)
                }
                log("model: compiling \(variant) for the Neural Engine")
                let started = Date()
                let config = WhisperKitConfig(
                    modelFolder: folder.path,
                    verbose: false,
                    logLevel: .error,
                    prewarm: true,
                    load: false,
                    download: false
                )
                _ = try await WhisperKit(config)
                ModelPreparationStamp.recordPrepared(variant: variant, folder: folder)
                log(String(
                    format: "model: %@ compiled in %.2fs",
                    variant, Date().timeIntervalSince(started)
                ))
            },
            onChange: onChange
        )
    }
}
