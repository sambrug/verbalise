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

        // Before anything else the user might try. Without a granted trigger
        // key the app is silently inert, which is exactly the confusion this
        // window exists to prevent.
        OnboardingWindow.showIfNeeded()

        // Pay CoreAudio's first-activation cost now, while nobody is waiting,
        // rather than on the user's first keypress.
        Task.detached(priority: .utility) { [rate = settings.sampleRate] in
            AudioPrewarm.run(sampleRate: Double(rate))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        menu?.show(status: "Ready")
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
                    alert: "Audio system is not responding. Use Restart from this menu."
                )
            }
        })
        self.session = session
        return session
    }

    private func startKeyTap() {
        if !Permissions.hasInputMonitoring {
            Permissions.requestInputMonitoring()
        }
        guard let combo = settings.triggerCombo else {
            log("config: trigger_key '\(settings.triggerKey)' is invalid, key tap not started")
            menu?.show(alert: "Trigger key '\(settings.triggerKey)' is not valid.")
            return
        }

        let tap = KeyTap(
            combo: combo,
            onChange: { [weak self] held in self?.triggerChanged(held: held) },
            onEscape: { Task { await AppDelegate.shared?.controller?.handleEscape() } }
        )
        keyTap = tap.start() ? tap : nil
        if keyTap == nil {
            menu?.show(alert: "Input Monitoring is not granted — the trigger key will not work.")
        }
    }

    private func triggerChanged(held: Bool) {
        guard let controller else { return }
        if settings.soundEnabled {
            held ? Sounds.playStart() : Sounds.playStop()
        }
        Task {
            if held {
                await controller.startRecording()
            } else {
                await controller.stopAndTranscribe()
            }
        }
    }

    // MARK: - Events

    private func handle(_ event: DictationEvent) {
        switch event {
        case .state(let state):
            menu?.show(state: state)

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

    private func show(phase: TranscriptionEngine.Phase) {
        switch phase {
        case .downloading(let fraction):
            menu?.show(status: fraction.map { "Downloading model \(Int($0 * 100))%" }
                ?? "Downloading model…")
        case .loading:
            menu?.show(status: "Loading model…")
        case .ready, .idle:
            break
        }
    }
}

// MARK: - StatusMenuDelegate

extension AppDelegate: StatusMenuDelegate {

    var currentSettings: Settings { settings }
    var currentStats: UsageStats { cachedStats }
    var currentRecent: [RecentTranscript] { cachedRecent }

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

        Task { [engine, controller, newSettings] in
            await engine?.apply(settings: newSettings)
            await controller?.apply(settings: newSettings)
        }

        if audioChanged {
            // Cheapest correct option: the controller holds the session, so a
            // full rebuild is the only way to swap it without adding a mutable
            // seam that exists purely for this.
            buildStack()
        }
        menu?.show(status: "Ready")
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

    /// Brings settings and lifetime stats across from the Python app.
    ///
    /// The user picks the folder, which is what makes reading outside the
    /// container sandbox-legal — the grant comes from their selection, not
    /// from an entitlement (plan §9 phase 6).
    func importFromPythonApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the Python app's data folder "
            + "(Application Support ▸ Open Whisper)."

        // Points at the usual location, but the user is free to go elsewhere —
        // this is a starting point, not a restriction.
        if let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) {
            panel.directoryURL = support.appendingPathComponent("Open Whisper")
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let result = PythonImport.read(from: directory, into: settings)
        guard result.importedSomething else {
            presentImportResult(result, summary: "Nothing was imported.")
            return
        }

        var summaryParts: [String] = []
        if let imported = result.settings {
            apply(settings: imported)
            summaryParts.append("settings")
        }
        if let importedStats = result.stats, let importedRecent = result.recent {
            summaryParts.append("\(importedStats.totalRecordings) recordings")
            replaceStats(importedStats, recent: importedRecent)
        } else if let importedStats = result.stats {
            summaryParts.append("\(importedStats.totalRecordings) recordings")
            replaceStats(importedStats, recent: cachedRecent)
        }

        presentImportResult(result, summary: "Imported \(summaryParts.joined(separator: " and ")).")
    }

    private func replaceStats(_ newStats: UsageStats, recent newRecent: [RecentTranscript]) {
        guard let stats else { return }
        Task {
            await stats.replace(stats: newStats, recent: newRecent)
            cachedStats = await stats.stats
            cachedRecent = await stats.recent
            lastTranscript = cachedRecent.first?.text
            if let text = lastTranscript { menu?.show(lastTranscript: text) }
        }
    }

    /// Always shown, including the notes. An import that silently skipped the
    /// user's vocabulary would be discovered much later, and by then they would
    /// have no idea why it was missing.
    private func presentImportResult(_ result: PythonImport.Result, summary: String) {
        let alert = NSAlert()
        alert.messageText = summary
        alert.informativeText = result.notes.isEmpty
            ? "Everything found was brought across."
            : result.notes.joined(separator: "\n\n")
        alert.alertStyle = result.importedSomething ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
                    AppDelegate.shared?.menu?.show(alert: "Restart failed — quit and reopen.")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
