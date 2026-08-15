import Foundation
import VerbaliseCore
import WhisperKit

/// Compiles downloaded models for the Neural Engine in the background.
///
/// Download and compile are the two halves of making a model usable, and
/// `ModelDownloader` already runs the first in the background so dictation can
/// carry on with the current model. This is the second half: as soon as a
/// tier's files land, pay its one-off multi-minute ANE compile *now*, while
/// the user is elsewhere — so that selecting the model later is a few-second
/// load instead of a several-minute wait behind a gated trigger key.
///
/// Separate from `TranscriptionEngine.ensureLoaded`, which compiles only the
/// selected model and keeps the result in memory to transcribe with. This
/// keeps nothing: `prewarm` without `load` walks every model component through
/// CoreML — which is what populates macOS's compile cache — and drops each one
/// as it goes, so preparing a three-gigabyte tier in the background does not
/// hold three gigabytes alongside the model dictation is using. The stamp is
/// the durable output, the same one `ensureLoaded` writes, so the engine later
/// recognises the model as ready-to-load-fast.
public actor ModelPreparer {

    /// Models whose background compile is running.
    public private(set) var inFlight: Set<TranscriptionModel> = []

    /// Fired whenever `inFlight` changes, carrying the snapshot, so the menu
    /// and the Settings window can show the compile without polling.
    private let onChange: @Sendable (Set<TranscriptionModel>) -> Void

    private var tasks: [TranscriptionModel: Task<Void, Never>] = [:]

    public init(onChange: @escaping @Sendable (Set<TranscriptionModel>) -> Void = { _ in }) {
        self.onChange = onChange
    }

    /// Starts a background compile, or does nothing if one is already running,
    /// the files are missing, or the model is already compiled.
    public func prepare(_ model: TranscriptionModel) {
        guard tasks[model] == nil else { return }
        let variant = model.whisperKitModelName
        guard let folder = TranscriptionEngine.existingFolder(for: variant),
              !ModelPreparationStamp.isPrepared(variant: variant, folder: folder)
        else { return }

        inFlight.insert(model)
        onChange(inFlight)

        tasks[model] = Task { [weak self] in
            do {
                log("model: compiling \(variant) in the background")
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
                    format: "model: %@ compiled in the background in %.2fs",
                    variant, Date().timeIntervalSince(started)
                ))
            } catch {
                // Not fatal, and nothing to tell the user: the engine repeats
                // the compile with full UI if the model is ever selected.
                log("model: background compile of \(variant) failed — "
                    + error.localizedDescription)
            }
            await self?.finish(model)
        }
    }

    private func finish(_ model: TranscriptionModel) {
        tasks[model] = nil
        inFlight.remove(model)
        onChange(inFlight)
    }
}
