import Foundation
import OpenWhisperCore
import WhisperKit

/// Fetches speech models the user has asked for but is not using yet.
///
/// Separate from `TranscriptionEngine.ensureLoaded`, which downloads only as a
/// side effect of needing a model *now*. The Settings window needs the other
/// case: fetch a tier in the background while dictation carries on with the
/// current one, show progress, and allow a cancel. Sharing the engine's storage
/// location is what makes the two meet -- whatever this fetches, the engine
/// later finds already on disk.
public actor ModelDownloader {

    /// In-flight downloads. The value is the fraction complete, or nil while the
    /// total size is still unknown.
    public private(set) var inFlight: [TranscriptionModel: Double?] = [:]

    /// Fired whenever `inFlight` changes, including on completion and failure,
    /// so the window can refresh without polling.
    ///
    /// Carries the snapshot rather than expecting the observer to read it back:
    /// the observer is typically the object that owns this downloader, and
    /// reaching back into it from its own initialiser is a circular reference.
    private let onChange: @Sendable ([TranscriptionModel: Double?]) -> Void

    private var tasks: [TranscriptionModel: Task<Void, Never>] = [:]
    private var failures: [TranscriptionModel: String] = [:]

    /// Cancelled downloads awaiting cleanup of whatever they had written.
    private var cancelled: Set<TranscriptionModel> = []

    public init(onChange: @escaping @Sendable ([TranscriptionModel: Double?]) -> Void = { _ in }) {
        self.onChange = onChange
    }

    /// The message from the last failed attempt at this tier, if any.
    public func failure(for model: TranscriptionModel) -> String? {
        failures[model]
    }

    /// Starts a download, or does nothing if one is already running or the model
    /// is already on disk.
    public func start(_ model: TranscriptionModel) {
        guard tasks[model] == nil else { return }
        guard !TranscriptionEngine.isDownloaded(model) else { return }

        failures[model] = nil
        // updateValue, not subscript assignment: the key must exist with a
        // nil value ("downloading, size unknown"), which `inFlight[model] = nil`
        // would instead delete.
        inFlight.updateValue(nil, forKey: model)
        onChange(inFlight)

        let variant = model.whisperKitModelName

        // Its own closure with its own capture list, rather than reaching for
        // `self` from inside the task: a weak reference captured by the outer
        // task is a mutable binding, which a @Sendable progress callback may
        // not read.
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { await self?.report(model, fraction: fraction) }
        }

        tasks[model] = Task { [weak self] in
            do {
                _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: TranscriptionEngine.modelStorage,
                    progressCallback: { progress in report(progress.fractionCompleted) }
                )
                log("model: \(variant) downloaded on request")
                await self?.finish(model, error: nil)
            } catch is CancellationError {
                await self?.finish(model, error: nil)
            } catch {
                log("model: \(variant) download failed — \(error.localizedDescription)")
                await self?.finish(model, error: error.localizedDescription)
            }
        }
    }

    /// Abandons a download and throws away what it had written.
    ///
    /// Abandons rather than guarantees a stop: WhisperKit owns the transfer and
    /// may run to completion regardless. What is guaranteed is that the app
    /// stops reporting it and stops waiting on it, and that nothing is left
    /// behind afterwards.
    ///
    /// The cleanup is the part that matters. "Is this model downloaded" is
    /// answered by asking whether its folder exists, so a cancelled download
    /// left its half-written folder looking exactly like a finished one -- the
    /// row went to "Remove" instead of back to "Download", and selecting it
    /// would have handed the engine an incomplete model.
    ///
    /// Deletion waits for the task to actually unwind. Deleting first races the
    /// transfer, which would simply write the files again on its way out.
    public func cancel(_ model: TranscriptionModel) {
        guard let task = tasks[model] else { return }

        cancelled.insert(model)
        task.cancel()
        tasks[model] = nil
        inFlight.removeValue(forKey: model)
        onChange(inFlight)

        Task { [weak self] in
            await task.value
            await self?.discardPartialDownload(model)
        }
    }

    private func discardPartialDownload(_ model: TranscriptionModel) {
        guard cancelled.remove(model) != nil else { return }
        TranscriptionEngine.removeDownload(model)
        // The row is still showing whatever it showed before the folder went;
        // this is what turns it back into "Download".
        onChange(inFlight)
    }

    private func report(_ model: TranscriptionModel, fraction: Double) {
        // A progress callback arriving after a cancel must not resurrect the
        // row: only update a download still considered live.
        guard tasks[model] != nil else { return }
        inFlight.updateValue(fraction > 0 ? fraction : nil, forKey: model)
        onChange(inFlight)
    }

    private func finish(_ model: TranscriptionModel, error: String?) {
        tasks[model] = nil
        inFlight.removeValue(forKey: model)
        failures[model] = error
        onChange(inFlight)
    }
}
