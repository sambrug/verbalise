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
        case loading
        case ready
    }

    public enum EngineError: Error, LocalizedError {
        /// The model's files aren't on disk, or haven't been through their
        /// first-use compile. The engine refuses rather than doing that work
        /// itself: a download or a compile started from inside a load is
        /// minutes of invisible work behind whatever UI asked for the load —
        /// the "stuck transcribing" with nothing on screen saying why. The
        /// provisioning pipeline owns those steps and shows them properly.
        case notReady

        public var errorDescription: String? {
            switch self {
            case .notReady:
                "The speech model isn't ready yet — it's still downloading or compiling."
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
    ///
    /// A downloaded copy only counts when it is *complete*. Quitting the app
    /// mid-download leaves the folder existing but missing files, and a bare
    /// existence check turned that into a permanent wedge: every load trusted
    /// the folder, failed on the missing file, and no download ever restarted
    /// because the folder "existed". The bundled copy is exempt — it shipped
    /// whole inside a signed bundle.
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
            if ModelFolder.isComplete(downloaded) {
                return downloaded
            }
        }
        return nil
    }

    /// Loads the configured model, provided the pipeline has finished with it
    /// — on disk and through its first-use compile — and throws
    /// `EngineError.notReady` otherwise. Safe to call repeatedly, and safe to
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

        // The engine loads; it never downloads and never compiles. Both used
        // to happen implicitly in here, which meant minutes of invisible work
        // could start from any code path that merely wanted the model in
        // memory — a transcription, a launch preload — with nothing on screen
        // saying so. The provisioning pipeline (ModelDownloader,
        // ModelPreparer) owns those steps now and reports them properly, so a
        // model that reaches this point loads in seconds. One that hasn't
        // been through the pipeline is refused, quickly and loudly.
        guard let folder = Self.existingFolder(for: variant),
              ModelPreparationStamp.isPrepared(variant: variant, folder: folder)
        else {
            throw EngineError.notReady
        }

        let wasCold = whisperKit == nil
        clearModel()

        onPhase(.loading)
        let loadStarted = Date()
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        let loaded: WhisperKit
        do {
            loaded = try await WhisperKit(config)
        } catch let error as WhisperError {
            // The folder passed the completeness check and still failed on a
            // missing file — a truncated blob inside an .mlmodelc, which no
            // existence check can see. Left in place it fails identically
            // forever; deleted, the next attempt re-downloads. Never the
            // bundled copy: it is read-only, shipped whole, and if *it* ever
            // failed this way deleting the download directory would be
            // aiming at the wrong thing.
            if case .modelsUnavailable = error, Self.downloadFolder(for: model) == folder {
                log("model: \(variant) is incomplete on disk, removing it so the next attempt re-downloads")
                try? FileManager.default.removeItem(at: folder)
            }
            throw error
        }

        // Cancelled while this was loading -- the tier changed, or the model was
        // unloaded outright. Installing it now would put back the very thing the
        // caller asked to be rid of.
        try Task.checkCancellation()
        whisperKit = loaded
        loadedModel = model

        // Performance parity with the Python (commit c778fd6), which logged
        // cold vs warm load separately. Peak GPU memory was MLX-specific and
        // has no WhisperKit equivalent, so it is simply not logged.
        log(String(
            format: "model: %@ loaded %@ in %.2fs",
            variant, wasCold ? "cold" : "warm", Date().timeIntervalSince(loadStarted)
        ))
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
