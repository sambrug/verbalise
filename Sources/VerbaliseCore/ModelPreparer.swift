import Foundation

/// The one place a model's first-use Neural Engine compile is allowed to run.
///
/// The compile is the expensive half of making a model usable: minutes of
/// ANECompilerService at full tilt, unabortable once started — macOS finishes
/// and caches it whatever the app does. Before this actor owned them, compiles
/// could start from two places at once (the engine loading the selected model,
/// the background preparer warming a spare), and switching models mid-compile
/// spawned a second compile of the same files next to the first. On the 8GB
/// machines this app actually runs on, concurrent compiles starve each other
/// badly enough that a 2.5-minute step stretches toward "is this ever going to
/// finish", which is the hang every lifecycle bug report traced back to.
///
/// So: one queue, one compile at a time, one task per model. A model already
/// queued or compiling is joined, never restarted. A model that became
/// prepared while it waited (a retry, a re-download that re-stamped) is
/// skipped when its turn comes. Nothing here is cancellable, deliberately —
/// the underlying compile isn't either, and a queue position is worth keeping:
/// switching away and back should find the work further along, not restarted.
///
/// The actual compile work is injected, so this logic — the part with the real
/// edge cases — tests in the fast suite without WhisperKit. The app wires the
/// real thing in `ModelPreparer.live`.
public actor ModelPreparer {

    /// Models queued or compiling, for the pane's "Compiling…" rows and the
    /// menu status. One set for both: a queued model is committed work the
    /// user is waiting on, and showing it as anything other than in progress
    /// would read as the app having forgotten it.
    public private(set) var inFlight: Set<TranscriptionModel> = []

    /// Fired whenever `inFlight` changes, carrying the snapshot, so the menu
    /// and the Settings window can show the compile without polling.
    private let onChange: @Sendable (Set<TranscriptionModel>) -> Void

    private let isPrepared: @Sendable (TranscriptionModel) -> Bool
    private let compile: @Sendable (TranscriptionModel) async throws -> Void

    private var tasks: [TranscriptionModel: Task<Void, Error>] = [:]

    /// The back of the queue. Each new compile awaits the previous one's
    /// completion — success or failure, either way the ANE is free again —
    /// which is what makes the queue serial without a scheduler.
    private var tail: Task<Void, Never>?

    public init(
        isPrepared: @escaping @Sendable (TranscriptionModel) -> Bool,
        compile: @escaping @Sendable (TranscriptionModel) async throws -> Void,
        onChange: @escaping @Sendable (Set<TranscriptionModel>) -> Void = { _ in }
    ) {
        self.isPrepared = isPrepared
        self.compile = compile
        self.onChange = onChange
    }

    /// Returns once the model is compiled, joining any compile already queued
    /// or running for it rather than starting another. Throws if the compile
    /// fails; the next call simply tries again.
    public func ensurePrepared(_ model: TranscriptionModel) async throws {
        // Join, don't duplicate: a second caller for the same model gets the
        // same outcome at the same moment.
        if let running = tasks[model] {
            try await running.value
            return
        }
        guard !isPrepared(model) else { return }

        inFlight.insert(model)
        onChange(inFlight)

        let previous = tail
        let isPrepared = isPrepared
        let compile = compile
        let task = Task {
            // Wait for the queue ahead, however it ended.
            _ = await previous?.value
            // The wait can outlive the need: the same files may have been
            // stamped while this sat queued. Compiling them again would spend
            // minutes proving nothing.
            guard !isPrepared(model) else { return }
            try await compile(model)
        }
        tasks[model] = task
        tail = Task { _ = try? await task.value }

        // Bookkeeping runs exactly once when the compile ends, whether or not
        // the caller that started it is still waiting.
        Task {
            let result = await task.result
            finish(model, result: result)
        }

        try await task.value
    }

    private func finish(_ model: TranscriptionModel, result: Result<Void, Error>) {
        tasks[model] = nil
        inFlight.remove(model)
        if case .failure(let error) = result {
            log("model: preparing \(model.rawValue) failed — \(error.localizedDescription)")
        }
        onChange(inFlight)
    }
}
