import Foundation

/// The one place model downloads run, whoever asked for them.
///
/// Downloads used to have two owners: this actor for fetches the user started
/// in the Settings window, and the engine for the model it needed to
/// transcribe with right now. Two owners meant two progress sources to merge,
/// and a Cancel button that silently did nothing whenever the engine happened
/// to be the one downloading — the row showed the engine's progress, but the
/// cancel went to an actor with no task to cancel. Now every fetch runs here:
/// one progress dictionary, one cancel that always works, one cleanup path.
///
/// `ensureDownloaded` is the entry point: it returns once the model is on
/// disk, joining a download already in flight rather than racing it. The
/// transfer work is injected so the join/cancel/cleanup logic — the part with
/// the real edge cases — tests in the fast suite without WhisperKit. The app
/// wires the real thing in `ModelDownloader.live`.
public actor ModelDownloader {

    /// In-flight downloads. The value is the fraction complete, or nil while
    /// the total size is still unknown.
    public private(set) var inFlight: [TranscriptionModel: Double?] = [:]

    /// Fired whenever `inFlight` changes, including on completion and failure,
    /// so the window can refresh without polling.
    private let onChange: @Sendable ([TranscriptionModel: Double?]) -> Void

    private let isDownloaded: @Sendable (TranscriptionModel) -> Bool
    private let download:
        @Sendable (TranscriptionModel, @escaping @Sendable (Double) -> Void) async throws -> Void
    private let removePartial: @Sendable (TranscriptionModel) -> Void

    private var tasks: [TranscriptionModel: Task<Void, Error>] = [:]

    /// Bumped per start and per cancel, so a progress callback from a dead
    /// transfer — one still unwinding after a cancel, or one superseded by a
    /// restart — can never repaint the row it no longer owns.
    private var generations: [TranscriptionModel: Int] = [:]

    /// Cancelled downloads awaiting cleanup of whatever they had written.
    private var cancelled: Set<TranscriptionModel> = []

    public init(
        isDownloaded: @escaping @Sendable (TranscriptionModel) -> Bool,
        download: @escaping @Sendable (
            TranscriptionModel, @escaping @Sendable (Double) -> Void
        ) async throws -> Void,
        removePartial: @escaping @Sendable (TranscriptionModel) -> Void,
        onChange: @escaping @Sendable ([TranscriptionModel: Double?]) -> Void = { _ in }
    ) {
        self.isDownloaded = isDownloaded
        self.download = download
        self.removePartial = removePartial
        self.onChange = onChange
    }

    /// Returns once the model is on disk, joining any download already running
    /// for it rather than starting another. Throws if the transfer fails, and
    /// throws `CancellationError` to every waiter if it is cancelled; the next
    /// call simply starts afresh.
    public func ensureDownloaded(_ model: TranscriptionModel) async throws {
        if let running = tasks[model] {
            try await running.value
            return
        }
        guard !isDownloaded(model) else { return }

        let generation = (generations[model] ?? 0) + 1
        generations[model] = generation
        // updateValue, not subscript assignment: the key must exist with a
        // nil value ("downloading, size unknown"), which `inFlight[model] = nil`
        // would instead delete.
        inFlight.updateValue(nil, forKey: model)
        onChange(inFlight)

        let download = download
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { await self?.report(model, generation: generation, fraction: fraction) }
        }
        let task = Task {
            try await download(model, report)
        }
        tasks[model] = task

        // Bookkeeping runs exactly once when the transfer ends, whether or not
        // the caller that started it is still waiting.
        Task {
            let result = await task.result
            finish(model, task: task, result: result)
        }

        try await task.value
    }

    /// Abandons a download and throws away what it had written.
    ///
    /// Abandons rather than guarantees a stop: the transfer layer owns the
    /// connection and may run on briefly regardless. What is guaranteed is
    /// that the app stops reporting it and stops waiting on it, and that
    /// nothing is left behind afterwards.
    ///
    /// The cleanup is the part that matters. "Is this model downloaded" is
    /// answered by asking whether its folder is complete, and a cancelled
    /// download's half-written folder must go back to reading as absent.
    ///
    /// Deletion waits for the task to actually unwind. Deleting first races
    /// the transfer, which would simply write the files again on its way out.
    public func cancel(_ model: TranscriptionModel) {
        guard let task = tasks[model] else { return }

        cancelled.insert(model)
        generations[model] = (generations[model] ?? 0) + 1
        task.cancel()
        // Cleared now, not when the transfer unwinds: the row flips back the
        // moment the user asks, and `finish` knows the bookkeeping is done
        // because the registered task no longer matches.
        tasks[model] = nil
        inFlight.removeValue(forKey: model)
        onChange(inFlight)

        Task { [weak self] in
            _ = await task.result
            await self?.discardPartialDownload(model)
        }
    }

    private func discardPartialDownload(_ model: TranscriptionModel) {
        guard cancelled.remove(model) != nil else { return }
        // A fresh download may have started while the cancelled transfer was
        // unwinding. Deleting now would pull that one's files out from under
        // it; the restart overwrites the leftovers anyway.
        guard tasks[model] == nil else { return }
        removePartial(model)
        // The row is still showing whatever it showed before the folder went;
        // this is what turns it back into "Download".
        onChange(inFlight)
    }

    private func report(_ model: TranscriptionModel, generation: Int, fraction: Double) {
        // A progress callback arriving after a cancel or restart must not
        // resurrect or repaint the row: only the live transfer reports.
        guard generations[model] == generation, tasks[model] != nil else { return }
        inFlight.updateValue(fraction > 0 ? fraction : nil, forKey: model)
        onChange(inFlight)
    }

    private func finish(
        _ model: TranscriptionModel,
        task: Task<Void, Error>,
        result: Result<Void, Error>
    ) {
        // A cancel already did this bookkeeping and may even have handed the
        // slot to a fresh download; only clean up after the task still on
        // record.
        guard tasks[model] == task else { return }
        tasks[model] = nil
        inFlight.removeValue(forKey: model)
        if case .failure(let error) = result, !(error is CancellationError) {
            log("model: download of \(model.rawValue) failed — \(error.localizedDescription)")
        }
        onChange(inFlight)
    }
}
