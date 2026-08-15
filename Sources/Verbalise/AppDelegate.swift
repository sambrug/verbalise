import AppKit
import VerbaliseCore
import VerbaliseSpeech

/// Wires the stack together and keeps the menu, pill and stats in step with
/// the state machine.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The emit callbacks handed to the actors are `@Sendable` and cannot hold
    /// `self` strongly without a retain cycle through them.
    private static weak var shared: AppDelegate?

    // MARK: - Event delivery

    /// Everything the actors report back — dictation events, engine phases,
    /// download and compile snapshots — funnelled through one stream and
    /// consumed in arrival order on the main actor.
    ///
    /// Each callback used to spawn its own unstructured `Task { @MainActor }`,
    /// and independent tasks carry no ordering guarantee: a pill "hide" could
    /// in principle land before the "transcribing" it was meant to clear,
    /// leaving the pill on screen forever, and a progress snapshot could
    /// overwrite a newer one with an older one. The stream's buffer is FIFO,
    /// which makes "events apply in the order they happened" a property of
    /// the plumbing rather than a hope about the scheduler.
    private enum AppEvent {
        case dictation(DictationEvent)
        case enginePhase(TranscriptionEngine.Phase)
        case downloads([TranscriptionModel: Double?])
        case prepares(Set<TranscriptionModel>)
    }

    private let events: AsyncStream<AppEvent>
    private let eventSink: AsyncStream<AppEvent>.Continuation
    private var eventPump: Task<Void, Never>?

    override init() {
        (events, eventSink) = AsyncStream.makeStream(of: AppEvent.self)
        super.init()
    }

    private func startEventPump() {
        eventPump = Task { [events] in
            for await event in events {
                AppDelegate.shared?.dispatch(event)
            }
        }
    }

    private func dispatch(_ event: AppEvent) {
        switch event {
        case .dictation(let event): handle(event)
        case .enginePhase(let phase): show(phase: phase)
        case .downloads(let inFlight): note(downloads: inFlight)
        case .prepares(let inFlight): note(prepares: inFlight)
        }
    }

    private var menu: StatusMenu?
    private var keyTap: KeyTap?
    private var pill: OverlayPill?

    private var settings = Settings()
    private let store = SettingsStore()
    private let stats = StatsStore()

    /// The model dictation uses right now.
    ///
    /// `settings.transcriptionModel` is the *selection* — intent, persisted
    /// the moment it is made. This is what is actually loaded and gating the
    /// trigger key, and it only ever moves ready-to-ready: selecting a tier
    /// that still needs downloading or compiling stages the switch, keeps
    /// dictation on the current model, and swaps automatically the moment the
    /// pipeline finishes. Before that split, selecting an unready tier
    /// killed dictation outright for however many minutes the download and
    /// compile took — clicking between models was the most dangerous thing
    /// in the app.
    private var activeModel: TranscriptionModel = .bundled

    /// What the engine is told: the user's settings with the *active* model,
    /// not the selected one. Language and vocabulary changes flow through
    /// immediately; the model only changes when a switch actually lands.
    private var engineSettings: Settings {
        var engineSettings = settings
        engineSettings.transcriptionModel = activeModel
        return engineSettings
    }

    /// A switch that was ready to land mid-dictation waits here for idle.
    private var activationPending = false

    private var controller: DictationController?
    private var session: AudioSession?
    private var engine: TranscriptionEngine?

    /// Fetches model files. Every download runs here, whoever asked — the
    /// Settings window, the launch preload, a refused keypress — so progress
    /// has one source and Cancel always has a task to cancel.
    private lazy var downloader = ModelDownloader.live { [eventSink] inFlight in
        eventSink.yield(.downloads(inFlight))
    }
    private var cachedDownloads: [TranscriptionModel: Double?] = [:]

    private func note(downloads inFlight: [TranscriptionModel: Double?]) {
        cachedDownloads = inFlight
        SettingsWindow.refreshIfOpen()
        refreshStatusLine()
    }

    /// Runs every first-use Neural Engine compile, one at a time. The engine
    /// itself never compiles; it waits for this.
    private lazy var preparer = ModelPreparer.live { [eventSink] inFlight in
        eventSink.yield(.prepares(inFlight))
    }
    private var cachedPrepares: Set<TranscriptionModel> = []

    private func note(prepares inFlight: Set<TranscriptionModel>) {
        cachedPrepares = inFlight
        SettingsWindow.refreshIfOpen()
        refreshStatusLine()
    }

    // MARK: - Provisioning

    /// The one pipeline that takes a tier from wherever it is to fully
    /// usable: download, then the one-off compile, then — if it is the
    /// selected model — the engine load.
    ///
    /// This replaces a web of "when X finishes, kick Y" callbacks whose gaps
    /// were where the lifecycle bugs lived: steps could be started twice,
    /// raced from two owners, or dropped between hand-offs. Each step joins
    /// work already in flight rather than duplicating it, so calling this is
    /// always safe — a repeat press of a dead trigger key, a re-selected
    /// model, a Download click on a tier already fetching all land in the
    /// same place.
    private var provisions: [TranscriptionModel: Task<Void, Never>] = [:]

    /// The last failed attempt per tier, for the pane's inline message.
    /// Cleared the moment a retry starts, so the row never shows yesterday's
    /// error over today's progress bar.
    private(set) var modelFailures: [TranscriptionModel: String] = [:]

    /// Which tier the menu's alert row is currently blaming, so a later
    /// success clears exactly that alert and never someone else's.
    private var alertedModelFailure: TranscriptionModel?

    private func provision(_ model: TranscriptionModel) {
        guard provisions[model] == nil else { return }
        modelFailures[model] = nil
        SettingsWindow.refreshIfOpen()
        provisions[model] = Task { [downloader, preparer] in
            var failure: String?
            var wasCancelled = false
            do {
                try await downloader.ensureDownloaded(model)
                try await preparer.ensurePrepared(model)
            } catch is CancellationError {
                wasCancelled = true
            } catch {
                failure = error.localizedDescription
            }
            AppDelegate.shared?.finishProvision(
                of: model, failure: failure, cancelled: wasCancelled
            )
        }
    }

    private func finishProvision(of model: TranscriptionModel, failure: String?, cancelled: Bool) {
        provisions[model] = nil
        defer {
            refreshStatusLine()
            SettingsWindow.refreshIfOpen()
        }
        if let failure {
            // Not fatal: the files are retried on the next ask — a keypress,
            // a re-click of Download, the next launch. But it must be seen:
            // inline on the tier's row, and — when it blocks the model the
            // user is waiting on — as the menu's alert row too.
            log("model: provisioning \(model.rawValue) failed — \(failure)")
            modelFailures[model] = failure
            if model == settings.transcriptionModel {
                menu?.show(alert: "Couldn't get \(model.displayName) ready — \(failure)")
                alertedModelFailure = model
            }
            return
        }
        if alertedModelFailure == model {
            menu?.clearAlert()
            alertedModelFailure = nil
        }
        if cancelled {
            // Cancelling the switch target's download is cancelling the
            // switch: the selection goes back to the model that was never
            // going anywhere. Leaving it pointed at a tier nothing is
            // fetching would strand the pane's checkmark on a model that
            // never arrives.
            if model == settings.transcriptionModel, model != activeModel {
                var reverted = settings
                reverted.transcriptionModel = activeModel
                apply(settings: reverted)
            }
            return
        }
        guard model == settings.transcriptionModel else { return }
        if model == activeModel {
            // The launch (or retry) provision of the model already in charge:
            // nothing to swap, just load it.
            loadEngine()
        } else {
            activateSelectedModel()
        }
    }

    /// Lands a staged switch: makes the selected model the active one.
    ///
    /// Only ever called once the selected model is fully provisioned. Waits
    /// out a dictation in flight — swapping the engine's model under a live
    /// recording trades a working transcription for a race — and lands on the
    /// next return to idle.
    private func activateSelectedModel() {
        let selected = settings.transcriptionModel
        guard selected != activeModel else {
            activationPending = false
            return
        }
        guard TranscriptionEngine.isPrepared(selected) else {
            // Ready-to-ready only. If the files changed since the pipeline
            // finished (deleted mid-switch, a stamp invalidated), run it
            // again rather than activating a model that cannot transcribe.
            provision(selected)
            return
        }
        guard dictationState == .idle else {
            activationPending = true
            return
        }
        activationPending = false
        activeModel = selected
        log("model: switching dictation to \(selected.rawValue)")
        syncEngine(thenLoad: true)
        refreshStatusLine()
        SettingsWindow.refreshIfOpen()
    }

    /// Pushes the current `engineSettings` to the engine, in order.
    ///
    /// Chained rather than fired as independent tasks: two pushes racing —
    /// say, a settings change and the activation it triggered — could land
    /// out of order and leave the engine on yesterday's model while the gate
    /// checks today's. The chain makes last-call-wins actually true.
    private var engineSync: Task<Void, Never>?

    private func syncEngine(thenLoad: Bool = false) {
        let snapshot = engineSettings
        let previous = engineSync
        engineSync = Task { [engine] in
            await previous?.value
            await engine?.apply(settings: snapshot)
            if thenLoad { AppDelegate.shared?.loadEngine() }
        }
    }

    private var cachedStats = UsageStats()
    private var cachedRecent: [RecentTranscript] = []
    private(set) var lastTranscript: String?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        log("Verbalise launched")

        startEventPump()
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
        provision(settings.transcriptionModel)
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
        eventSink.finish()
        eventPump?.cancel()
        log("Verbalise terminating")
    }

    /// Gives the editor windows working Cut/Copy/Paste/Select All.
    ///
    /// `NSTextView` does not implement those shortcuts itself — it relies on
    /// the main menu's key equivalents reaching it through the responder
    /// chain. An `LSUIElement` app has no main menu at all, so ⌘C did nothing.
    /// This is the same gap that made legacy-python/menubar.py:374 hand-build an editor and
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
        // At launch the selection is the active model by definition: there is
        // no previous model to keep dictating with, so if it needs work the
        // trigger key gates until the pipeline finishes, exactly as before.
        activeModel = settings.transcriptionModel
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

        let engine = TranscriptionEngine(settings: engineSettings) { [eventSink] phase in
            eventSink.yield(.enginePhase(phase))
        }

        let controller = DictationController(
            session: makeSession(),
            transcriber: engine,
            inserter: TextInserter(keyboard: SystemKeyboard(), pasteboard: SystemPasteboard()),
            settings: settings,
            emit: { [eventSink] event in
                eventSink.yield(.dictation(event))
            }
        )

        self.engine = engine
        self.controller = controller
        // The old chain belongs to the engine it was pushing to.
        engineSync = nil
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
                        + "Restart Verbalise in Settings ▸ General."
                )
            }
        })
        self.session = session
        return session
    }

    /// Loads the provisioned model into memory in the background.
    ///
    /// Only ever called for a model the pipeline has finished with, so this is
    /// a few-second cached load, never a download or compile. A failure is not
    /// fatal and deliberately does not alert: the next dictation retries, and
    /// a transient problem at launch should not greet the user with a dialog
    /// about something they were not doing.
    private func loadEngine() {
        guard let engine else { return }
        Task.detached(priority: .utility) {
            do {
                try await engine.ensureLoaded()
            } catch {
                log("model: load failed — \(error.localizedDescription)")
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
            menu?.show(alert: "'\(settings.triggerKey)' isn't a trigger key Verbalise recognises.")
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

            // Refuse while the *active* model cannot transcribe yet — with a
            // staged switch in flight the active model is by construction
            // ready, so this only ever gates the first provision of a fresh
            // selection (typically first launch). Recording into a
            // multi-minute wait produces a dictation that looks hung, and the
            // user has no way to tell it apart from a crash — better to say
            // so and let them try again in a moment. Two waits qualify: a
            // download, and the ANE compile on the first load of freshly
            // downloaded files — and the stamp check covers both, since a
            // model with no complete folder cannot be stamped. A *cached*
            // load stays ungated — it takes a few seconds, which is time the
            // user spends speaking anyway.
            // A refusal shows little of its own: the pulsing menu bar icon
            // and the clickable status line are already reporting the wait,
            // and both started when the wait did, not at this keypress. (An
            // alert row and a pill flash were tried and retired here — one
            // broke the menu's pattern, the other the pill's shape.)
            if !TranscriptionEngine.isPrepared(activeModel) {
                log("dictation: refused, the speech model isn't ready")
                // The one addition at the keypress itself: the refusal sound,
                // so "not ready yet" is tellable from "broken" without
                // touching the pill.
                if settings.soundEnabled { Sounds.playUnavailable() }
                // Make sure the missing work is actually underway. Joins
                // whatever is already running; a repeat press cannot start
                // anything twice.
                provision(settings.transcriptionModel)
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
            // A switch that was ready mid-dictation lands now, before the
            // status line redraws, so the menu never shows the old model as
            // current for a frame longer than it is.
            if state == .idle, activationPending {
                activateSelectedModel()
            }
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
        case .loading:
            break
        case .ready:
            // The idle countdown starts from the moment there is something to
            // unload, not from launch.
            Task { await lifecycle.noteLoaded() }
        case .idle:
            Task { await lifecycle.noteUnloaded() }
        }
        refreshStatusLine()
    }

    /// Whether the trigger key would be refused right now: the active model's
    /// files are missing or haven't been through their first-use compile.
    /// With a staged switch in flight the active model stays ready, so this
    /// is true only while the selection itself is being provisioned for the
    /// first time.
    private var dictationGated: Bool {
        !TranscriptionEngine.isPrepared(activeModel)
    }

    /// One extra line of the compile/download hint while a switch is staged,
    /// so nobody wonders whether they can dictate meanwhile. Nil when the
    /// working tier IS the selection, where the wait really does gate.
    private var stagedHint: String? {
        guard settings.transcriptionModel != activeModel else { return nil }
        return "Dictation keeps using \(activeModel.displayName) until then."
    }

    /// The status line's one writer.
    ///
    /// The dictation state and the engine phase both wanted this line, and
    /// with each writing it directly the last writer won — which is how
    /// Escape during a stuck transcription left the menu saying "Ready" while
    /// the model was still minutes from loaded (#8). Deriving the line from
    /// both here means neither can contradict the other: dictation activity
    /// outranks engine phases, and an idle dictation shows whatever the
    /// pipeline is doing to the *selected* model. Background work on other
    /// tiers deliberately doesn't show: dictation works throughout, so there
    /// is nothing to pull the eye to; the Speech Model pane shows it to
    /// whoever goes looking.
    private func refreshStatusLine() {
        // The pulse runs exactly as long as dictation is gated — the one
        // signal that means "the key won't work yet". A staged switch never
        // pulses: dictation keeps working, and the status line alone carries
        // the progress. First, so the icon it resets on the way out is
        // immediately re-asserted by whichever show() call follows.
        menu?.setPulsing(dictationState == .idle && dictationGated)

        switch dictationState {
        case .recording:
            menu?.show(state: .recording)
            if enginePhase != .ready {
                menu?.show(status: "Recording… (waking speech model)")
            }
        case .transcribing:
            menu?.show(state: .transcribing)
        case .idle:
            // Every download and compile is the pipeline's now, so the caches
            // are the whole story; the engine only ever adds a few seconds of
            // "Loading model…".
            if let fraction = cachedDownloads[settings.transcriptionModel] {
                show(downloadStatus: fraction)
            } else if cachedPrepares.contains(settings.transcriptionModel) {
                showCompilingStatus()
            } else if enginePhase == .loading {
                menu?.show(status: "Loading model…")
            } else if dictationGated {
                // Nothing is running and the key would still be refused — a
                // failed provision (the alert row has the specifics), or work
                // that hasn't started. "Ready — hold X" here would be a lie
                // the very next keypress exposes.
                menu?.show(status: "\(activeModel.displayName) isn't ready")
            } else {
                menu?.show(state: .idle)
            }
        }
    }

    private func show(downloadStatus fraction: Double?) {
        let name = settings.transcriptionModel.displayName
        menu?.show(
            status: fraction.map { "Downloading \(name) \(Int($0 * 100))%" }
                ?? "Downloading \(name)…",
            hint: stagedHint
        )
    }

    private func showCompilingStatus() {
        let explainer = "macOS is preparing the model for this Mac's Neural Engine — "
            + "a one-off step after each download that takes a few minutes."
        // Only a gating compile pauses dictation; a staged one explains
        // itself instead.
        let tail = stagedHint ?? "Dictation is paused until it finishes."
        menu?.show(
            status: "Compiling \(settings.transcriptionModel.displayName)…",
            hint: "\(explainer) \(tail)"
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

    /// The model dictation actually uses right now — behind the selection
    /// while a staged switch is still downloading or compiling.
    var activeTranscriptionModel: TranscriptionModel { activeModel }

    /// Which tiers are on disk. Asked fresh rather than cached: a download that
    /// finished a second ago must show as available, and the answer is a
    /// filesystem check on three paths.
    var downloadedModels: Set<TranscriptionModel> {
        TranscriptionEngine.downloadedModels
    }

    /// In-flight downloads. One source now — every download runs in the
    /// downloader, so this is the whole truth and Cancel always has a task
    /// behind it.
    var modelDownloads: [TranscriptionModel: Double?] {
        cachedDownloads
    }

    /// Models queued or running in the compile queue. One source, same
    /// reasoning.
    var compilingModels: Set<TranscriptionModel> {
        cachedPrepares
    }

    /// The pane's Download button. Through the full pipeline, not just the
    /// fetch: a downloaded-but-uncompiled tier would still cost minutes at
    /// selection time, and paying that now, in the background, is the whole
    /// point of pre-fetching.
    func downloadModel(_ model: TranscriptionModel) {
        provision(model)
    }

    func cancelModelDownload(_ model: TranscriptionModel) {
        Task { await downloader.cancel(model) }
    }

    var removableModels: Set<TranscriptionModel> {
        // Never the model in use, and never the selection: removing what is
        // loaded would leave the next dictation with nothing to transcribe
        // with, and removing a staged switch's target would delete the files
        // its own pipeline is working on. The pane offers no way to ask for
        // either.
        TranscriptionEngine.removableModels
            .subtracting([settings.transcriptionModel, activeModel])
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
    /// what changed (the Python did this on SIGHUP, legacy-python/daemon.py:904).
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

        // A selection change either lands now (the tier is ready: a
        // few-second engine swap) or stages: the pipeline downloads and
        // compiles in the background while dictation carries on with the
        // active model, and finishProvision lands the switch when it's done.
        // Every step joins work already in flight — a tier mid-download or
        // mid-compile keeps its place and its progress row; nothing restarts.
        if old.transcriptionModel != newSettings.transcriptionModel {
            if TranscriptionEngine.isPrepared(newSettings.transcriptionModel) {
                activateSelectedModel()
            } else {
                provision(newSettings.transcriptionModel)
            }
        }

        // The engine gets the settings with the *active* model substituted —
        // decided above — so language and vocabulary changes apply
        // immediately while the model only moves when a switch lands.
        syncEngine()
        Task { [controller, newSettings] in
            await controller?.apply(settings: newSettings)
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
