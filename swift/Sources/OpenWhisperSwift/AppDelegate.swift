import AppKit
import OpenWhisperCore
import OpenWhisperSpeech

/// Wires the stack together and keeps the menu, pill and stats in step with
/// the state machine.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The emit callbacks handed to the actors are `@Sendable` and cannot hold
    /// `self` strongly without a retain cycle through them.
    private static weak var shared: AppDelegate?

    private var menu: StatusMenu?
    private var keyTap: KeyTap?
    private var pill: OverlayPill?

    private var settings = Settings()
    private let store = SettingsStore()
    private let stats = StatsStore()

    private var controller: DictationController?
    private var session: AudioSession?
    private var engine: TranscriptionEngine?

    /// Fetches tiers the user asked for but is not using yet. Separate from the
    /// engine, which downloads only what it needs to transcribe right now.
    private lazy var downloader = ModelDownloader { inFlight in
        Task { @MainActor in
            AppDelegate.shared?.note(downloads: inFlight)
        }
    }
    private var cachedDownloads: [TranscriptionModel: Double?] = [:]

    private func note(downloads inFlight: [TranscriptionModel: Double?]) {
        let finished = Set(cachedDownloads.keys).subtracting(inFlight.keys)
        cachedDownloads = inFlight
        SettingsWindow.refreshIfOpen()
        // A download of the *selected* model drives the status line and the
        // pulse, so they must notice it starting and finishing.
        refreshStatusLine()

        // Download and compile are two halves of one lifecycle, so a fetch
        // that just landed flows straight into its one-off ANE compile — now,
        // while the user is elsewhere, not on their next keypress (#8). The
        // selected model compiles in the engine, which keeps the result to
        // dictate with; any other compiles in the background and keeps
        // nothing. `isDownloaded` filters out the other ways a download
        // leaves `inFlight`: a cancel or a failure leaves no folder behind.
        for model in finished where TranscriptionEngine.isDownloaded(model) {
            if model == settings.transcriptionModel {
                preloadModel()
            } else {
                Task { await preparer.prepare(model) }
            }
        }
    }

    /// Compiles downloaded-but-unselected tiers in the background, so
    /// switching to them later is seconds, not minutes.
    private lazy var preparer = ModelPreparer { inFlight in
        Task { @MainActor in
            AppDelegate.shared?.note(prepares: inFlight)
        }
    }
    private var cachedPrepares: Set<TranscriptionModel> = []

    private func note(prepares inFlight: Set<TranscriptionModel>) {
        let finished = cachedPrepares.subtracting(inFlight)
        cachedPrepares = inFlight
        SettingsWindow.refreshIfOpen()
        refreshStatusLine()

        // The user selected a model while its background compile was still
        // running; it is ready now, so give the engine its fast load.
        if finished.contains(settings.transcriptionModel),
           TranscriptionEngine.isPrepared(settings.transcriptionModel) {
            preloadModel()
        }
    }

    private var cachedStats = UsageStats()
    private var cachedRecent: [RecentTranscript] = []
    private(set) var lastTranscript: String?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        log("Open Whisper (Swift) launched")

        installEditMenu()
        loadSettings()
        menu = StatusMenu(delegate: self)
        buildStack()
        startKeyTap()
        loadStats()
        observePermissionGrants()

        // Ask for Input Monitoring once, on the first launch that could still
        // be answered.
        //
        // The prompt is the smaller half of what this call is for.
        // `CGRequestListenEventAccess` is also the app's only opportunity to be
        // *registered* in System Settings' Input Monitoring list at all, and
        // macOS does not always take it. Never calling it makes the absence
        // certain rather than intermittent -- anyone who opens that pane before
        // touching ours would find nothing there to switch on, and would have to
        // add the app by hand with `+`.
        let prompting = !Permissions.hasInputMonitoring
            && !Permissions.hasPrompted(for: .inputMonitoring)
        if prompting {
            Permissions.recordPrompted(for: .inputMonitoring)
            Permissions.requestInputMonitoring()
        }

        // Before anything else the user might try. Without a granted trigger
        // key the app is silently inert, which is exactly the confusion the
        // Permissions pane exists to prevent.
        if CommandLine.arguments.contains("--settings") {
            // A menu bar app's Settings window is otherwise three clicks and a
            // menu-bar hover away, which is tedious when checking a layout and
            // impossible from a script.
            showSettings()
        } else if !prompting {
            // Skipped only on the one launch that just put the system prompt on
            // screen -- our window and Apple's asking at the same moment is the
            // collision this ordering exists to avoid. It can happen once per
            // install, because the request above can only prompt once; on every
            // later launch this branch runs as before.
            SettingsWindow.showIfPermissionsMissing(delegate: self)
        }

        // Pay CoreAudio's first-activation cost now, while nobody is waiting,
        // rather than on the user's first keypress.
        Task.detached(priority: .utility) { [rate = settings.sampleRate] in
            AudioPrewarm.run(sampleRate: Double(rate))
        }

        // Same reasoning for the speech model: get it ready before the first
        // keypress instead of during it. A model already loaded once before
        // takes a few seconds; one that needs fetching, or whose files have
        // never been loaded (the multi-minute first-use ANE compile), shows
        // its progress in the menu and gates the trigger key until it's done.
        preloadModel()
        startIdleTimer()
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let self = AppDelegate.shared else { return }
                self.checkPermissionGrants()
                let minutes = self.settings.advanced.modelIdleUnloadMinutes
                let recording = self.dictationState != .idle
                Task { await self.lifecycle.maybeUnload(
                    idleMinutes: minutes, isRecording: recording
                ) }
            }
        }
    }

    /// Last seen Input Monitoring state, so the grant can be acted on the
    /// moment it lands rather than only noticed.
    private var hadInputMonitoring = Permissions.hasInputMonitoring

    /// Watches for Input Monitoring arriving while nothing is open to notice.
    ///
    /// The Settings window polls too, but it stops the moment it closes -- and
    /// the path this app most often takes is the one that ends outside it:
    /// macOS frequently fails to register the app in the Input Monitoring list,
    /// so the user adds it by hand in System Settings, long after our window
    /// was dismissed. A tap built before the grant existed never delivers an
    /// event, so without a check that outlives the window the trigger key stays
    /// dead until the app happens to be relaunched, with nothing saying so.
    ///
    /// Becoming active covers coming back from System Settings; the idle timer
    /// covers a menu bar app that is never activated at all.
    private func observePermissionGrants() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppDelegate.shared?.checkPermissionGrants()
            }
        }
    }

    func checkPermissionGrants() {
        let hasIt = Permissions.hasInputMonitoring
        defer { hadInputMonitoring = hasIt }
        guard hasIt, !hadInputMonitoring else { return }
        log("permissions: Input Monitoring granted, rebuilding the key tap")
        reinstallKeyTap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        idleTimer?.invalidate()
        inputPreview.stop()
        keyTap?.stop()
        pill?.quit()
        log("Open Whisper (Swift) terminating")
    }

    /// Gives the editor windows working Cut/Copy/Paste/Select All.
    ///
    /// `NSTextView` does not implement those shortcuts itself — it relies on
    /// the main menu's key equivalents reaching it through the responder
    /// chain. An `LSUIElement` app has no main menu at all, so ⌘C did nothing.
    /// This is the same gap that made menubar.py:374 hand-build an editor and
    /// lose clipboard support doing it; the fix is to supply the menu rather
    /// than to reimplement the commands.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )

        let editItem = NSMenuItem()
        editItem.submenu = edit

        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Loading

    private func loadSettings() {
        guard let store else {
            log("config: no container path available, using defaults")
            return
        }
        let result = store.load()
        settings = result.settings
        for error in result.validation.errors {
            log("config error: \(error)")
        }
        if !result.validation.isValid {
            menu?.show(alert: result.validation.errors.joined(separator: " · "))
        }
        log("config: model=\(settings.transcriptionModel.rawValue) trigger=\(settings.triggerKey)")
    }

    private func loadStats() {
        guard let stats else { return }
        Task {
            await stats.load()
            cachedStats = await stats.stats
            cachedRecent = await stats.recent
            lastTranscript = cachedRecent.first?.text
            if let text = lastTranscript { menu?.show(lastTranscript: text) }
        }
    }

    // MARK: - Stack

    private let meter = LevelMeter()

    /// Drives the Settings input level meter. Never runs during a dictation.
    let inputPreview = InputPreview()

    /// Drops the speech model after a long idle spell (plan §3, group 11).
    ///
    /// This was ported and tested in Phase 3 and then never connected, which
    /// made `model_idle_unload_minutes` a setting that validated, defaulted to
    /// 120, and did nothing -- the model stayed resident until quit. Whether
    /// the ANE makes the reload cheap is beside the point: a menu bar app that
    /// sits idle all afternoon holding a multi-gigabyte model is a bad citizen.
    private lazy var lifecycle = ModelLifecycle {
        Task { @MainActor in
            await AppDelegate.shared?.engine?.unload()
            AppDelegate.shared?.menu?.show(state: .idle)
        }
    }

    /// Checks the idle threshold. A minute is plenty for a timeout measured in
    /// hours, and costs nothing while nothing is happening.
    private var idleTimer: Timer?

    private func buildStack() {
        pill = OverlayPill(style: settings.overlayStyle, meter: meter)

        let engine = TranscriptionEngine(settings: settings) { phase in
            Task { @MainActor in AppDelegate.shared?.show(phase: phase) }
        }

        let controller = DictationController(
            session: makeSession(),
            transcriber: engine,
            inserter: TextInserter(keyboard: SystemKeyboard(), pasteboard: SystemPasteboard()),
            settings: settings,
            emit: { event in
                Task { @MainActor in AppDelegate.shared?.handle(event) }
            }
        )

        self.engine = engine
        self.controller = controller
        refreshStatusLine()
    }

    /// Rebuilt whenever the device or sample rate changes, since both are fixed
    /// for a stream's lifetime.
    private func makeSession() -> AudioSession {
        let opener = AVAudioCaptureOpener(
            sampleRate: Double(settings.sampleRate),
            deviceName: settings.inputDevice,
            onSamples: { samples in
                Task { await AppDelegate.shared?.controller?.appendAudio(samples) }
            },
            // Straight into the meter: no actor hop, no allocation, nothing
            // that could stall the realtime audio thread. The pill samples it
            // on its own timer.
            onLevel: { [meter] level in
                meter.report(level)
            }
        )
        let session = AudioSession(opener: opener, onEscalate: {
            // Single process: no supervisor to relaunch us, so this becomes a
            // persistent alert pointing at Restart (plan §3).
            Task { @MainActor in
                AppDelegate.shared?.menu?.show(
                    alert: "The audio system has stopped responding. "
                        + "Restart Open Whisper in Settings ▸ General."
                )
            }
        })
        self.session = session
        return session
    }

    /// Loads the model in the background at launch, and after a model change.
    ///
    /// A failure here is not fatal and deliberately does not alert: the next
    /// dictation retries, and a transient network problem at launch should not
    /// greet the user with a dialog about something they were not doing.
    private func preloadModel() {
        guard let engine else { return }
        Task.detached(priority: .utility) {
            do {
                try await engine.ensureLoaded()
            } catch {
                log("model: preload failed — \(error.localizedDescription)")
            }
        }
    }

    private func startKeyTap() {
        // Replacing an existing tap, not adding to it. An event tap installed
        // before Input Monitoring was granted stays permanently deaf -- it
        // installs happily and simply never delivers -- so the tap has to be
        // torn down and rebuilt once the grant lands.
        keyTap?.stop()
        keyTap = nil

        // No permission request here: this runs again on every rebuild, and by
        // then the grant either exists or the answer is already standing.
        // `applicationDidFinishLaunching` owns the one first-run request.
        guard let combo = settings.triggerCombo else {
            log("config: trigger_key '\(settings.triggerKey)' is invalid, key tap not started")
            menu?.show(alert: "'\(settings.triggerKey)' isn't a trigger key Open Whisper recognises.")
            return
        }

        let tap = KeyTap(
            combo: combo,
            onChange: { [weak self] held in self?.triggerChanged(held: held) },
            onEscape: { Task { await AppDelegate.shared?.controller?.handleEscape() } }
        )
        keyTap = tap.start() ? tap : nil
        if keyTap == nil {
            menu?.show(alert: "Input Monitoring isn't granted, so the trigger key won't work.")
        }
    }

    private func triggerChanged(held: Bool) {
        guard let controller, let engine else { return }

        if held {
            // Whatever the Settings window is doing with the microphone, the
            // dictation gets it.
            inputPreview.stop()

            // Refuse while the model cannot transcribe yet. Recording into a
            // multi-minute wait produces a dictation that looks hung, and the
            // user has no way to tell it apart from a crash — better to say so
            // and let them try again in a moment. Two waits qualify: a
            // download, and the ANE compile on the first load of freshly
            // downloaded files. A *cached* load stays ungated — it takes a few
            // seconds, which is time the user spends speaking anyway.
            // A refusal shows nothing of its own: the pulsing menu bar icon
            // and the clickable status line are already reporting the wait,
            // and both started when the wait did, not at this keypress. (An
            // alert row and a pill flash were tried and retired here — one
            // broke the menu's pattern, the other the pill's shape.)
            let model = settings.transcriptionModel
            var downloading = cachedDownloads.keys.contains(model)
            if case .downloading = enginePhase { downloading = true }
            if downloading {
                log("dictation: refused, model still downloading")
                return
            }
            // Asked of the stamp rather than the phase, because the phase
            // cannot warn about work that has not started yet: the compile may
            // still be queued behind a preload, or not be underway at all.
            if enginePhase != .ready, !TranscriptionEngine.isPrepared(model) {
                log("dictation: refused, model needs its first-use compile")
                // Make sure that compile is actually underway — unless the
                // background preparer already has it, in which case a second,
                // racing compile of the same files helps nobody. Repeat
                // presses join whichever is running.
                if !cachedPrepares.contains(model) {
                    preloadModel()
                }
                return
            }
            if settings.soundEnabled { Sounds.playStart() }

            Task {
                // Load in parallel with the recording rather than after it.
                // Only ever a cached load by this point — the gate above
                // refused anything slower — so it takes a few seconds, which
                // is time the user spends speaking anyway; by the time they
                // let go it is usually ready and the wait disappears entirely.
                // The status line notices on its own ("Recording… (waking
                // speech model)") via refreshStatusLine.
                if await !engine.isLoaded {
                    Task.detached { try? await engine.ensureLoaded() }
                }
                await lifecycle.noteActivity()
                await controller.startRecording()
            }
        } else {
            if settings.soundEnabled { Sounds.playStop() }
            Task { await controller.stopAndTranscribe() }
        }
    }

    // MARK: - Events

    private var dictationState: DictationState = .idle

    private func handle(_ event: DictationEvent) {
        switch event {
        case .state(let state):
            dictationState = state
            refreshStatusLine()

        case .pill(let command):
            switch command {
            case .show(let state): pill?.show(state: state)
            case .setState(let state): pill?.set(state: state)
            case .hide: pill?.hide()
            }

        case .lastText(let text):
            lastTranscript = text
            menu?.show(lastTranscript: text)
            menu?.noteDictationCompleted()
            record(text)

        case .warning(let message):
            menu?.show(alert: message)
            log("warning: \(message)")

        case .error(let message):
            menu?.show(alert: message)
            log("error: \(message)")

        case .statsChanged:
            break // Recorded on .lastText, which carries the text to count.
        }
    }

    private func record(_ text: String) {
        guard let stats else { return }
        Task {
            await stats.record(text)
            cachedStats = await stats.stats
            cachedRecent = await stats.recent
        }
    }

    private var enginePhase: TranscriptionEngine.Phase = .idle

    private func show(phase: TranscriptionEngine.Phase) {
        enginePhase = phase
        switch phase {
        case .downloading, .preparing, .loading:
            break
        case .ready:
            // The idle countdown starts from the moment there is something to
            // unload, not from launch.
            Task { await lifecycle.noteLoaded() }
        case .idle:
            Task { await lifecycle.noteUnloaded() }
        }
        refreshStatusLine()
        // The engine downloads too, and the Settings window must show that as
        // one download rather than none -- otherwise a model fetched on the way
        // to a dictation appears in the list as simply missing.
        SettingsWindow.refreshIfOpen()
    }

    /// The status line's one writer.
    ///
    /// The dictation state and the engine phase both wanted this line, and
    /// with each writing it directly the last writer won — which is how
    /// Escape during a stuck transcription left the menu saying "Ready" while
    /// the model was still minutes from loaded (#8). Deriving the line from
    /// both here means neither can contradict the other: dictation activity
    /// outranks engine phases, and an idle dictation shows whatever the
    /// engine is doing.
    /// Whether the selected model is mid-download or mid-compile — the two
    /// waits dictation is gated behind. Background work on *other* tiers
    /// deliberately doesn't count: dictation works throughout, so there is
    /// nothing to pull the eye to; the Speech Model pane shows it to whoever
    /// goes looking.
    private var selectedModelBusy: Bool {
        switch enginePhase {
        case .downloading, .preparing:
            return true
        case .loading, .ready, .idle:
            return cachedDownloads.keys.contains(settings.transcriptionModel)
                || cachedPrepares.contains(settings.transcriptionModel)
        }
    }

    private func refreshStatusLine() {
        // The pulse runs exactly as long as the selected model is unusable.
        // First, so the icon it resets on the way out is immediately
        // re-asserted by whichever show() call follows.
        menu?.setPulsing(dictationState == .idle && selectedModelBusy)

        switch dictationState {
        case .recording:
            menu?.show(state: .recording)
            if enginePhase != .ready {
                menu?.show(status: "Recording… (waking speech model)")
            }
        case .transcribing:
            menu?.show(state: .transcribing)
        case .idle:
            switch enginePhase {
            case .downloading(let fraction):
                show(downloadStatus: fraction)
            case .preparing:
                showCompilingStatus()
            case .loading:
                menu?.show(status: "Loading model…")
            case .ready, .idle:
                // The engine is quiet, but the selected model may be moving
                // through its lifecycle elsewhere: fetched by the downloader,
                // or compiled by the background preparer.
                if let fraction = cachedDownloads[settings.transcriptionModel] {
                    show(downloadStatus: fraction)
                } else if cachedPrepares.contains(settings.transcriptionModel) {
                    showCompilingStatus()
                } else {
                    menu?.show(state: .idle)
                }
            }
        }
    }

    private func show(downloadStatus fraction: Double?) {
        menu?.show(status: fraction.map { "Downloading model \(Int($0 * 100))%" }
            ?? "Downloading model…")
    }

    private func showCompilingStatus() {
        menu?.show(
            status: "Compiling speech model…",
            hint: "macOS is preparing the model for this Mac's Neural Engine — "
                + "a one-off step after each download that takes a few minutes. "
                + "Dictation is paused until it finishes."
        )
    }
}

// MARK: - StatusMenuDelegate

extension AppDelegate: StatusMenuDelegate {

    var currentRecent: [RecentTranscript] { cachedRecent }
    var triggerDisplayName: String? { settings.triggerCombo?.displayName }

    func showSettings() {
        SettingsWindow.show(delegate: self)
    }

    func showSpeechModelSettings() {
        SettingsWindow.show(pane: .speechModel, delegate: self)
    }
}

// MARK: - SettingsDelegate

extension AppDelegate: SettingsDelegate {

    var currentSettings: Settings { settings }
    var currentStats: UsageStats { cachedStats }

    /// Which tiers are on disk. Asked fresh rather than cached: a download that
    /// finished a second ago must show as available, and the answer is a
    /// filesystem check on three paths.
    var downloadedModels: Set<TranscriptionModel> {
        TranscriptionEngine.downloadedModels
    }

    /// In-flight downloads from both sources — the explicit ones the user
    /// started in the window, and the implicit one the engine starts when the
    /// configured model is missing.
    var modelDownloads: [TranscriptionModel: Double?] {
        var all = cachedDownloads
        if case .downloading(let fraction) = enginePhase {
            all.updateValue(fraction, forKey: settings.transcriptionModel)
        }
        return all
    }

    /// Models mid first-use compile, from both sources — the selected one the
    /// engine is compiling to dictate with, and any the preparer is compiling
    /// in the background.
    var compilingModels: Set<TranscriptionModel> {
        var all = cachedPrepares
        if enginePhase == .preparing {
            all.insert(settings.transcriptionModel)
        }
        return all
    }

    func downloadModel(_ model: TranscriptionModel) {
        Task { await downloader.start(model) }
    }

    func cancelModelDownload(_ model: TranscriptionModel) {
        Task { await downloader.cancel(model) }
    }

    var removableModels: Set<TranscriptionModel> {
        // Never the model in use: removing what is loaded would leave the next
        // dictation with nothing to transcribe with, and the pane offers no
        // way to ask for that.
        TranscriptionEngine.removableModels.subtracting([settings.transcriptionModel])
    }

    func removeModel(_ model: TranscriptionModel) {
        TranscriptionEngine.removeDownload(model)
    }

    func showLog() {
        LogWindow.show()
    }

    func setInputPreview(active: Bool) {
        guard active else {
            inputPreview.stop()
            return
        }
        // Two engines on one microphone is needless risk against the one path
        // that must not break. The meter can wait; a dictation cannot.
        guard dictationState == .idle else {
            log("mic preview: not starting, a dictation is in progress")
            return
        }
        inputPreview.start(sampleRate: settings.sampleRate, deviceName: settings.inputDevice)
    }

    func reinstallKeyTap() {
        startKeyTap()
        if keyTap != nil { menu?.clearAlert() }
    }

    /// Applies a settings change live, rebuilding only what actually depends on
    /// what changed (the Python did this on SIGHUP, daemon.py:904).
    func apply(settings newSettings: Settings) {
        let validation = newSettings.validate()
        guard validation.isValid else {
            // Reject wholesale rather than half-apply, matching the Python.
            menu?.show(alert: validation.errors.joined(separator: " · "))
            return
        }

        let old = settings
        settings = newSettings
        try? store?.save(newSettings)

        if old.triggerKey != newSettings.triggerKey, let combo = newSettings.triggerCombo {
            keyTap?.update(combo: combo)
        }
        if old.overlayStyle != newSettings.overlayStyle {
            pill?.apply(style: newSettings.overlayStyle)
        }

        // A device or sample-rate change needs a new stream, and both are fixed
        // for a stream's lifetime — so the session is replaced rather than
        // reconfigured.
        let audioChanged = old.inputDevice != newSettings.inputDevice
            || old.sampleRate != newSettings.sampleRate
        if audioChanged {
            log("config: audio input changed, rebuilding the session")
        }

        // preloadModel's doc promised "after a model change" from the start,
        // but nothing called it — so a switched model sat unloaded until the
        // next keypress, and if its files had never been loaded before, that
        // keypress ran into the full first-use compile. Two hands-off cases:
        // an absent tier is already being fetched by the ModelDownloader
        // (SettingsWindow.select starts that), and a tier mid-background-
        // compile is already being prepared — in both, a second worker on the
        // same files would only race the first. note(downloads:)/(prepares:)
        // pick each up the moment it finishes.
        let modelChanged = old.transcriptionModel != newSettings.transcriptionModel

        // Switching away mid-compile abandons the engine's load, but not the
        // compile: hand it to the background preparer, so the tier keeps its
        // "Compiling…" row in the pane — the same way a background download
        // keeps its bar — and its place in the pipeline. The preparer's work
        // mostly lands in macOS's cache warm from the abandoned load, so this
        // costs little and makes the finish observable (the stamp, the row
        // clearing, the fast load if the user switches back).
        if modelChanged, enginePhase == .preparing {
            let abandoned = old.transcriptionModel
            Task { await preparer.prepare(abandoned) }
        }

        Task { [engine, controller, newSettings] in
            await engine?.apply(settings: newSettings)
            await controller?.apply(settings: newSettings)
            if modelChanged,
               TranscriptionEngine.isDownloaded(newSettings.transcriptionModel),
               AppDelegate.shared?.cachedPrepares.contains(newSettings.transcriptionModel) != true {
                AppDelegate.shared?.preloadModel()
            }
        }

        if audioChanged {
            // Cheapest correct option: the controller holds the session, so a
            // full rebuild is the only way to swap it without adding a mutable
            // seam that exists purely for this.
            buildStack()
        }
        refreshStatusLine()
    }

    func clearRecentTranscripts() {
        guard let stats else { return }
        Task {
            await stats.clearRecent()
            cachedRecent = await stats.recent
        }
    }

    func openConfigFile() {
        guard let url = store?.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Relaunches. Replaces the Python supervisor's restart, and is what the
    /// escalation alert points the user at when the audio subsystem wedges.
    func restart() {
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    log("restart failed: \(error.localizedDescription)")
                    AppDelegate.shared?.menu?.show(alert: "Restart didn't work — quit and reopen.")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
