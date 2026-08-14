import AppKit
import OpenWhisperCore
import OpenWhisperSpeech

/// Wires the real stack together: key tap -> state machine -> audio, speech,
/// and text insertion.
///
/// The menu here is deliberately minimal — enough to see state, fix
/// permissions, and quit. The full tree (settings, recent transcripts,
/// editors, stats) is Phase 5.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var keyTap: KeyTap?

    private var settings = Settings()
    private let store = SettingsStore()

    private var controller: DictationController?
    private var session: AudioSession?
    private var engine: TranscriptionEngine?

    private var statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var lastTranscript: String?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("Open Whisper (Swift) launched")
        loadSettings()
        buildStatusItem()
        buildStack()
        startKeyTap()

        // Pay CoreAudio's first-activation cost now, while nobody is waiting,
        // rather than on the user's first keypress.
        Task.detached(priority: .utility) { [sampleRate = settings.sampleRate] in
            AudioPrewarm.run(sampleRate: Double(sampleRate))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyTap?.stop()
        log("Open Whisper (Swift) terminating")
    }

    // MARK: - Wiring

    private func loadSettings() {
        guard let store else {
            log("config: no container path available, using defaults")
            return
        }
        let result = store.load()
        settings = result.settings
        if !result.validation.isValid {
            for error in result.validation.errors {
                log("config error: \(error)")
            }
        }
        log("config: model=\(settings.transcriptionModel.rawValue) trigger=\(settings.triggerKey)")
    }

    private func buildStack() {
        // Audio samples arrive on a realtime thread. They are handed straight
        // to the controller actor and nothing else happens here — the tap must
        // never block.
        let opener = AVAudioCaptureOpener(
            sampleRate: Double(settings.sampleRate),
            deviceName: settings.inputDevice,
            onSamples: { [weak self] samples in
                Task { await self?.controller?.appendAudio(samples) }
            }
        )

        let session = AudioSession(
            opener: opener,
            onEscalate: {
                // Single process: no supervisor to relaunch us, so this
                // surfaces as a persistent alert pointing at Restart (plan §3).
                log("audio: subsystem wedged beyond in-process recovery")
                Task { @MainActor in
                    NSApp.requestUserAttention(.criticalRequest)
                }
            }
        )

        let engine = TranscriptionEngine(settings: settings) { phase in
            Task { @MainActor in
                AppDelegate.shared?.show(phase: phase)
            }
        }

        let inserter = TextInserter(
            keyboard: SystemKeyboard(),
            pasteboard: SystemPasteboard()
        )

        controller = DictationController(
            session: session,
            transcriber: engine,
            inserter: inserter,
            settings: settings,
            emit: { event in
                Task { @MainActor in
                    AppDelegate.shared?.handle(event)
                }
            }
        )
        self.session = session
        self.engine = engine
        AppDelegate.shared = self
        refreshStatus("Ready")
    }

    /// The emit callbacks are `@Sendable` and cannot capture `self` strongly
    /// without a retain cycle through the actors they are handed to.
    private static weak var shared: AppDelegate?

    private func startKeyTap() {
        if !Permissions.hasInputMonitoring {
            Permissions.requestInputMonitoring()
        }
        guard let combo = settings.triggerCombo else {
            log("config: trigger_key '\(settings.triggerKey)' is invalid, key tap not started")
            refreshStatus("Invalid trigger key")
            return
        }

        let tap = KeyTap(
            combo: combo,
            onChange: { [weak self] held in
                self?.triggerChanged(held: held)
            },
            onEscape: { [weak self] in
                Task { await self?.controller?.handleEscape() }
            }
        )
        keyTap = tap.start() ? tap : nil
        if keyTap == nil {
            refreshStatus("Input Monitoring needed")
        }
    }

    private func triggerChanged(held: Bool) {
        guard let controller else { return }
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
            switch state {
            case .idle: refreshStatus("Ready")
            case .recording: refreshStatus("Recording…")
            case .transcribing: refreshStatus("Transcribing…")
            }
        case .lastText(let text):
            lastTranscript = text
            log("transcript: \(text.prefix(60))")
        case .warning(let message):
            refreshStatus(message)
            log("warning: \(message)")
        case .error(let message):
            refreshStatus(message)
            log("error: \(message)")
        case .pill, .statsChanged:
            break // Phase 5.
        }
    }

    private func show(phase: TranscriptionEngine.Phase) {
        switch phase {
        case .downloading(let fraction):
            if let fraction {
                refreshStatus("Downloading model \(Int(fraction * 100))%")
            } else {
                refreshStatus("Downloading model…")
            }
        case .loading: refreshStatus("Loading model…")
        case .ready, .idle: break
        }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Open Whisper Swift"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Copy Last Transcript",
                     action: #selector(copyLast), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reveal Log File",
                     action: #selector(revealLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Config",
                     action: #selector(openConfig), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Open Whisper Swift",
                     action: #selector(quit), keyEquivalent: "q").target = self

        item.menu = menu
        statusItem = item
    }

    private func refreshStatus(_ text: String) {
        statusLine.title = text
    }

    // MARK: - Actions

    @objc private func copyLast() {
        guard let lastTranscript else { return }
        SystemPasteboard().write(lastTranscript)
    }

    @objc private func revealLog() {
        guard let url = Log.shared.logFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openConfig() {
        guard let url = store?.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if keyTap == nil, Permissions.hasInputMonitoring {
            // The grant may have landed after launch.
            startKeyTap()
        }
    }
}
