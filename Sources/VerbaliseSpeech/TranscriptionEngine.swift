import Foundation
import VerbaliseCore
import WhisperKit

/// WhisperKit behind the `Transcriber` seam (plan §3), replacing the Python's
/// `mlx_whisper` path (legacy-python/daemon.py:1074).
///
/// Isolated in its own module so the heavy dependency never reaches
/// `VerbaliseCore`, which the recovery tests build against.
public actor TranscriptionEngine: Transcriber {

    public enum Phase: Sendable, Equatable {
        case idle
        /// 0...1, or nil while the total size is still unknown.
        case downloading(Double?)
        /// The first load of these model files: CoreML is compiling them for
        /// the Neural Engine, which takes minutes, not the seconds `loading`
        /// implies. A separate phase because the two deserve opposite UI --
        /// dictation can ride out a cached load, but recording into a compile
        /// produces a dictation that looks hung (#8).
        case preparing
        case loading
        case ready
    }

    public enum EngineError: Error, LocalizedError {
        case noStorage

        public var errorDescription: String? {
            switch self {
            case .noStorage: "Could not find a place to store speech models."
            }
        }
    }

    private var whisperKit: WhisperKit?
    private var loadedModel: TranscriptionModel?

    /// The load currently running, and the tier it is loading.
    ///
    /// An actor is re-entrant at every `await`, and loading suspends for
    /// seconds. Without somewhere to record that a load is already in flight,
    /// each caller arriving during that window sees `whisperKit == nil`, decides
    /// no model is loaded, and starts its own -- and there are several callers
    /// by design: the launch preload, the parallel wake when a dictation starts,
    /// and one per streaming chunk. Those loads then contend, so each takes far
    /// longer than it would alone, which widens the window, which admits more of
    /// them. Observed in the wild as a model that loads in 1.5s taking 57s, or
    /// simply never finishing.
    private var loadTask: Task<Void, Error>?
    private var loadingModel: TranscriptionModel?
    /// Distinguishes "my load finished" from "mine was replaced", without
    /// relying on task identity.
    private var loadGeneration = 0

    private var settings: Settings
    private let onPhase: @Sendable (Phase) -> Void

    public init(
        settings: Settings = Settings(),
        onPhase: @escaping @Sendable (Phase) -> Void = { _ in }
    ) {
        self.settings = settings
        self.onPhase = onPhase
    }

    public func apply(settings: Settings) {
        // A model change invalidates the loaded instance; everything else
        // (language, vocabulary) is applied per call and needs no reload.
        if settings.transcriptionModel != self.settings.transcriptionModel {
            unload()
        }
        self.settings = settings
    }

    public var isLoaded: Bool { whisperKit != nil }

    /// Whether a *given* tier is on disk.
    ///
    /// `nonisolated` because the Settings window asks about all three tiers
    /// every time its list refreshes, and none of those answers depend on actor
    /// state -- they are a question about the filesystem.
    public nonisolated static func isDownloaded(_ model: TranscriptionModel) -> Bool {
        existingFolder(for: model.whisperKitModelName) != nil
    }

    /// Which tiers are on disk right now.
    public nonisolated static var downloadedModels: Set<TranscriptionModel> {
        Set(TranscriptionModel.allCases.filter(isDownloaded))
    }

    /// Whether a tier's files have been loaded once before, so the ANE
    /// compile is behind them and the next load takes seconds.
    ///
    /// `nonisolated` for the same reason as `isDownloaded`: the answer is a
    /// question about the filesystem and stored stamps, not actor state, and
    /// the caller that gates the trigger key cannot wait on a loading actor
    /// to answer it.
    public nonisolated static func isPrepared(_ model: TranscriptionModel) -> Bool {
        guard let folder = existingFolder(for: model.whisperKitModelName) else { return false }
        return ModelPreparationStamp.isPrepared(
            variant: model.whisperKitModelName, folder: folder
        )
    }

    /// Which tiers can be deleted to reclaim space.
    ///
    /// Downloaded copies only. The bundled tier lives inside the app bundle,
    /// which is read-only under the sandbox and is the reason a fresh install
    /// works with no network -- removing it is neither possible nor wanted.
    public nonisolated static var removableModels: Set<TranscriptionModel> {
        Set(TranscriptionModel.allCases.filter { downloadFolder(for: $0) != nil })
    }

    /// The container copy of a model, if there is one. Never the bundled copy.
    private nonisolated static func downloadFolder(for model: TranscriptionModel) -> URL? {
        guard let storage = modelStorage else { return nil }
        let folder = storage
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(model.whisperKitModelName, isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// Deletes a downloaded model, reclaiming its disk.
    ///
    /// Without this a model could be fetched and never removed: the `accurate`
    /// tier is three gigabytes, and deleting the whole app was the only way to
    /// get it back.
    ///
    /// Never called for the model in use — the pane offers Remove only on a
    /// tier that is downloaded and not selected, so this cannot pull the
    /// engine's own files out from under it.
    @discardableResult
    public nonisolated static func removeDownload(_ model: TranscriptionModel) -> Bool {
        guard let folder = downloadFolder(for: model) else { return false }
        do {
            try FileManager.default.removeItem(at: folder)
            log("model: removed downloaded \(model.whisperKitModelName)")
            return true
        } catch {
            log("model: could not remove \(model.whisperKitModelName) — "
                + error.localizedDescription)
            return false
        }
    }

    // MARK: - Model storage

    /// Where downloaded models live.
    ///
    /// Explicitly inside the app container, never `~/.cache/huggingface`. Under
    /// the sandbox `.applicationSupportDirectory` already resolves into the
    /// container, so this both satisfies App Store rule 2.5.2 and keeps a
    /// multi-gigabyte download out of the user's home directory where nothing
    /// would ever clean it up.
    static var modelStorage: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Models", isDirectory: true)
    }

    // MARK: - Loading

    /// Where a model already sits, if it does. Checked before any download.
    ///
    /// The bundled copy comes first: `balanced` ships inside the app, so a
    /// fresh install must be able to dictate immediately rather than waiting
    /// on a download it does not need.
    static func existingFolder(for variant: String) -> URL? {
        if let bundled = Bundle.main.url(
            forResource: variant, withExtension: nil, subdirectory: "Models"
        ), FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // WhisperKit lays downloads out as <base>/models/<repo>/<variant>.
        if let storage = modelStorage {
            let downloaded = storage
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(variant, isDirectory: true)
            if FileManager.default.fileExists(atPath: downloaded.path) {
                return downloaded
            }
        }
        return nil
    }

    /// Downloads if needed, then loads. Safe to call repeatedly, and safe to
    /// call concurrently: callers arriving while a load is running wait on that
    /// load rather than starting another.
    public func ensureLoaded() async throws {
        let model = settings.transcriptionModel
        if whisperKit != nil, loadedModel == model { return }

        // Join the load already in flight rather than racing it.
        if let loadTask, loadingModel == model {
            try await loadTask.value
            return
        }

        // A different tier was asked for mid-load, so that load's result is no
        // longer wanted.
        loadTask?.cancel()

        loadGeneration &+= 1
        let generation = loadGeneration
        let task = Task {
            do {
                try await self.performLoad(model)
            } catch {
                // A failed load leaves nothing loaded, and the phase must say
                // so — otherwise the menu sits on "Compiling…" (pulsing, no
                // less) for a load that is no longer happening. Not on
                // cancellation: that means a newer load replaced this one and
                // is already reporting its own phases, which an .idle from
                // here would stomp.
                if !(error is CancellationError) { self.onPhase(.idle) }
                throw error
            }
        }
        loadTask = task
        loadingModel = model
        defer {
            // Only if it is still ours: a newer load may have replaced it while
            // this one was suspended.
            if loadGeneration == generation {
                loadTask = nil
                loadingModel = nil
            }
        }
        try await task.value
    }

    private func performLoad(_ model: TranscriptionModel) async throws {
        let variant = model.whisperKitModelName
        let wasCold = whisperKit == nil
        clearModel()

        // Download and load are timed separately. Folding them together makes
        // a nine-minute first run look like a nine-minute model load, which is
        // exactly the wrong conclusion to draw when tuning startup.
        var downloadSeconds: TimeInterval = 0
        let folder: URL

        if let existing = Self.existingFolder(for: variant) {
            folder = existing
            log("model: using existing \(variant) at \(existing.lastPathComponent)")
        } else {
            let downloadStarted = Date()
            defer { downloadSeconds = Date().timeIntervalSince(downloadStarted) }
            // Download explicitly rather than letting the config do it
            // implicitly, so there is a progress figure to show. The Python
            // app's silent "Loading…" on first use of a model is what this
            // replaces -- a download this size with no feedback reads as a
            // freeze.
            onPhase(.downloading(nil))
            folder = try await WhisperKit.download(
                variant: variant,
                downloadBase: Self.modelStorage,
                progressCallback: { [onPhase] progress in
                    let fraction = progress.fractionCompleted
                    onPhase(.downloading(fraction > 0 ? fraction : nil))
                }
            )
        }

        // A first load of these files is an ANE compile measured in minutes;
        // say so, both to the UI and to the log -- "loaded cold in 3.8s" and
        // "loaded cold in 8 minutes" are different events, and telling them
        // apart is what the stamp exists for (#8).
        let prepared = ModelPreparationStamp.isPrepared(variant: variant, folder: folder)
        if prepared {
            onPhase(.loading)
        } else {
            log("model: first load of \(variant), compiling for the Neural Engine")
            onPhase(.preparing)
        }
        let loadStarted = Date()
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        let loaded = try await WhisperKit(config)

        // Stamped before the cancellation check, deliberately: the compile
        // happened whether or not anyone still wants the result. Switching
        // tiers mid-compile cancels this load, but macOS finishes and caches
        // the compile anyway — so the stamp must say so, or coming back to
        // this model would present the whole multi-minute wait again for a
        // load that will actually take seconds.
        ModelPreparationStamp.recordPrepared(variant: variant, folder: folder)

        // Cancelled while this was loading -- the tier changed, or the model was
        // unloaded outright. Installing it now would put back the very thing the
        // caller asked to be rid of.
        try Task.checkCancellation()
        whisperKit = loaded
        loadedModel = model

        // Performance parity with the Python (commit c778fd6), which logged
        // cold vs warm load separately. Peak GPU memory was MLX-specific and
        // has no WhisperKit equivalent, so it is simply not logged.
        // "first" marks a load that included the ANE compile, so its number is
        // never mistaken for what a routine load costs.
        let loadSeconds = Date().timeIntervalSince(loadStarted)
        let temperature = prepared ? (wasCold ? "cold" : "warm") : "first"
        if downloadSeconds > 0 {
            log(String(
                format: "model: %@ downloaded in %.0fs, loaded %@ in %.2fs",
                variant, downloadSeconds, temperature, loadSeconds
            ))
        } else {
            log(String(
                format: "model: %@ loaded %@ in %.2fs",
                variant, temperature, loadSeconds
            ))
        }
        onPhase(.ready)
    }

    /// Drops the loaded model, and abandons any load still running: an unload
    /// while loading means the result is no longer wanted, and letting it land
    /// afterwards would silently undo the unload.
    public func unload() {
        loadTask?.cancel()
        loadTask = nil
        loadingModel = nil
        clearModel()
    }

    /// The state half of `unload`, without the cancellation -- `performLoad`
    /// calls this to clear the way for itself, and must not cancel the task it
    /// is itself running inside.
    private func clearModel() {
        whisperKit = nil
        loadedModel = nil
        onPhase(.idle)
    }

    // MARK: - Transcribe

    public func transcribe(_ audio: [Float]) async throws -> String {
        try await ensureLoaded()
        guard let whisperKit else { return "" }

        let started = Date()
        let results = try await whisperKit.transcribe(
            audioArray: audio,
            decodeOptions: decodingOptions(for: whisperKit)
        )
        let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

        let elapsed = Date().timeIntervalSince(started)
        let audioSeconds = Double(audio.count) / Double(max(settings.sampleRate, 1))
        log(String(
            format: "transcribe: %.1fs audio in %.2fs (%.1fx realtime)",
            audioSeconds, elapsed, elapsed > 0 ? audioSeconds / elapsed : 0
        ))
        return text
    }

    private func decodingOptions(for whisperKit: WhisperKit) -> DecodingOptions {
        var options = DecodingOptions()

        // Distil models are English-only; effectiveLanguage already enforces
        // that regardless of what the config says.
        options.language = settings.effectiveLanguage
        options.task = .transcribe

        // Timestamps are pure overhead here: the transcript is typed straight
        // into the focused app, never displayed as subtitles.
        options.withoutTimestamps = true

        // The equivalent of the Python's condition_on_previous_text = false.
        // Each dictation is transcribed standalone, so no previous window's
        // text is carried in as context -- which is what stops one dictation's
        // phrasing bleeding into the next.
        options.usePrefillPrompt = true

        if let promptTokens = vocabularyPromptTokens(for: whisperKit) {
            options.promptTokens = promptTokens
        }
        return options
    }

    /// Biases decoding toward the user's domain terms.
    ///
    /// The `Vocabulary: a, b.` wording is the exact format the Python uses
    /// (legacy-python/daemon.py:1087) and is kept verbatim -- prompt phrasing measurably
    /// changes what the model favours, so this is not a detail to improve on
    /// while porting.
    private func vocabularyPromptTokens(for whisperKit: WhisperKit) -> [Int]? {
        let terms = settings.vocabulary.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !terms.isEmpty, let tokenizer = whisperKit.tokenizer else { return nil }

        let prompt = "Vocabulary: \(terms.joined(separator: ", "))."
        let tokens = tokenizer.encode(text: prompt)
        return tokens.isEmpty ? nil : tokens
    }
}
