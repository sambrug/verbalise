import AppKit
import Combine
import VerbaliseCore
import SwiftUI

/// What the Settings window needs from the app.
///
/// Deliberately not `StatusMenuDelegate` widened: the menu now shows state and
/// the window now owns configuration, and giving each the surface it actually
/// uses is what keeps that split honest.
@MainActor
protocol SettingsDelegate: AnyObject {
    var currentSettings: VerbaliseCore.Settings { get }
    var currentStats: UsageStats { get }
    func apply(settings: VerbaliseCore.Settings)

    /// The model dictation actually uses right now. Differs from
    /// `currentSettings.transcriptionModel` while a staged switch is still
    /// downloading or compiling — the checkmark shows the selection, the
    /// "In use" badge shows this.
    var activeTranscriptionModel: TranscriptionModel { get }

    var downloadedModels: Set<TranscriptionModel> { get }
    var modelDownloads: [TranscriptionModel: Double?] { get }
    /// Models queued or running in the first-use Neural Engine compile queue.
    var compilingModels: Set<TranscriptionModel> { get }
    /// The last download/compile failure per tier, cleared when a retry
    /// starts. Shown inline on the row.
    var modelFailures: [TranscriptionModel: String] { get }
    func downloadModel(_ model: TranscriptionModel)
    func cancelModelDownload(_ model: TranscriptionModel)
    /// Deletes a downloaded model. Only ever called for one not in use.
    func removeModel(_ model: TranscriptionModel)
    var removableModels: Set<TranscriptionModel> { get }

    func openConfigFile()
    func showLog()
    func restart()

    /// Re-read the grants and rebuild the key tap if Input Monitoring has just
    /// landed. Owned by the app, not the window, so that a grant made after the
    /// window closes is still acted on.
    func checkPermissionGrants()

    /// Opens the microphone to drive the input level meter, and closes it
    /// again. Refused while a dictation is running.
    var inputPreview: InputPreview { get }
    func setInputPreview(active: Bool)
}

/// The Settings window, replacing the status menu's `Settings ▸` submenu.
///
/// A submenu was the wrong shape for this: it could not show a model
/// downloading, could not hold the permission rows, and made every toggle a
/// four-level hover. It also meant the eleven settings were only ever visible
/// one at a time, so nothing could be compared against anything else.
///
/// SwiftUI rather than AppKit, alone in this app apart from the pill. The
/// grouped-inset list, the sidebar and the form metrics are all stock controls
/// here and hand-built ones in AppKit; matching macOS is the whole point of the
/// window, so using the components that already match it is the shorter path to
/// the same place.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    private static var shared: SettingsWindow?

    private let window: NSWindow
    private let model: SettingsModel
    private var titleObserver: AnyCancellable?
    private var permissionTimer: Timer?

    /// Opens the window, optionally jumping straight to a pane.
    static func show(pane: SettingsPane? = nil, delegate: any SettingsDelegate) {
        let existing = shared ?? SettingsWindow(delegate: delegate)
        shared = existing
        existing.model.delegate = delegate
        if let pane { existing.model.selection = pane }

        existing.model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        let firstShow = !existing.window.isVisible && existing.window.frame.origin == .zero
        existing.window.makeKeyAndOrderFront(nil)
        if firstShow { existing.window.center() }
        existing.startPollingPermissions()
    }

    /// First run, and any later run where a grant has been revoked.
    ///
    /// Replaces the separate onboarding window: the permission rows now live in
    /// the pane that also explains the rest of the app, so there is one place to
    /// send someone rather than two that overlap.
    static func showIfPermissionsMissing(delegate: any SettingsDelegate) {
        guard PermissionsState.needsSetup(for: delegate.currentSettings) else { return }
        show(pane: .permissions, delegate: delegate)
    }

    /// Pushes fresh download progress into an already-open window.
    static func refreshIfOpen() {
        shared?.model.refresh()
    }

    private init(delegate: any SettingsDelegate) {
        model = SettingsModel(delegate: delegate)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            // No .fullSizeContentView: it hands the titlebar to the content,
            // which makes macOS draw the window with its large-title chrome —
            // an oversized corner radius and the pane name repeated as a
            // heading inside the content. A plain titled window gets the
            // system's standard radius and puts the title where it belongs.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 560))
        // Resizable with a floor. System Settings resizes too, and the panes
        // here are not all the same height -- Vocabulary's two editors need
        // more room than Trigger Key's single picker, and without this the
        // taller ones had their closing footer cut off at the window edge.
        window.contentMinSize = NSSize(width: 660, height: 460)
        // Reopens where it was left, which is what every other Mac window does.
        // Versioned: the split view stores its divider position against
        // this name, and a stale one overrode the sidebar width.
        window.setFrameAutosaveName("SettingsWindow.v6")
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))

        super.init()
        window.delegate = self

        // The pane name in the title bar, the way System Settings does it,
        // rather than a second large heading repeated inside the content.
        titleObserver = model.$selection.sink { [weak self] pane in
            self?.window.title = pane.title
        }
    }

    /// TCC changes raise no notification, so the Permissions pane can only find
    /// out by asking. Polling runs while the window is open and stops when it
    /// closes.
    private func startPollingPermissions() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { SettingsWindow.shared?.model.refreshPermissions() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        // The microphone must not stay open behind a closed window.
        model.stopInputPreview()
        // Anything still sitting in a debounce is written now rather than lost.
        model.flushPendingEdits()
    }
}

// MARK: - Panes

/// Five panes, not seven.
///
/// Trigger Key, Audio and Text Output were three panes holding four controls
/// between them -- a sidebar navigating to near-empty rooms. They are one
/// Dictation pane now, which also puts the trigger key next to the microphone,
/// since those are the pair people reason about together.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case dictation
    case speechModel
    case vocabulary
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .speechModel: "Speech Model"
        case .vocabulary: "Vocabulary"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "switch.2"
        case .dictation: "mic.fill"
        case .speechModel: "sparkles"
        case .vocabulary: "book.fill"
        case .permissions: "lock.fill"
        }
    }

    /// The tinted rounded square System Settings puts beside every row.
    ///
    /// Permissions is red rather than another neutral. It was `.secondary`,
    /// which rendered so close to General's `.gray` that the first and last
    /// rows read as a matched pair for no reason -- and of the five, it is the
    /// one whose row can be broken.
    var tint: Color {
        switch self {
        case .general: .gray
        case .dictation: .orange
        case .speechModel: .purple
        case .vocabulary: .brown
        case .permissions: .red
        }
    }
}

/// The TCC grants the running variant actually needs, read together.
enum PermissionsState {
    static func needsSetup(for settings: VerbaliseCore.Settings) -> Bool {
        #if APPSTORE
        // The hotkey trigger needs nothing, and the Accessibility-pane grant
        // is only in play while auto insertion is selected. In clipboard mode
        // the app is microphone-only.
        if !Permissions.hasMicrophone { return true }
        return settings.insertionMode == .auto && !Permissions.hasPostEvent
        #else
        return !Permissions.hasInputMonitoring
            || !Permissions.hasPostEvent
            || !Permissions.hasMicrophone
        #endif
    }
}

// MARK: - Model

/// The window's state, and the only thing that talks to the app.
///
/// Everything here is a cache refreshed on demand rather than a second source
/// of truth: `Settings` still lives in the AppDelegate and is still written by
/// `apply(settings:)`, which validates. A settings window that kept its own
/// copy would be one rejected validation away from showing something the app is
/// not doing.
@MainActor
final class SettingsModel: ObservableObject {

    @Published var selection: SettingsPane = .general
    @Published private(set) var settings: VerbaliseCore.Settings
    @Published private(set) var stats = UsageStats()
    @Published private(set) var rows: [ModelRow] = []
    /// What dictation uses right now; trails the selection during a staged
    /// switch, and the pane's footer explains the difference while it lasts.
    @Published private(set) var activeModel: TranscriptionModel = .bundled
    @Published private(set) var inputDevices: [String] = []
    @Published private(set) var launchesAtLogin = false

    /// Bumped whenever a grant changes, to redraw the permission rows and the
    /// sidebar's attention dot without diffing three booleans by hand.
    @Published private(set) var permissionsRevision = 0

    weak var delegate: (any SettingsDelegate)?

    /// Text panes commit on a debounce; this runs the pending one immediately.
    var pendingEdit: (() -> Void)?

    init(delegate: any SettingsDelegate) {
        self.delegate = delegate
        settings = delegate.currentSettings
        refresh()
    }

    func refresh() {
        guard let delegate else { return }
        settings = delegate.currentSettings
        stats = delegate.currentStats
        activeModel = delegate.activeTranscriptionModel
        rows = ModelCatalog.rows(
            active: activeModel,
            downloaded: delegate.downloadedModels,
            downloading: delegate.modelDownloads,
            removable: delegate.removableModels,
            compiling: delegate.compilingModels,
            failures: delegate.modelFailures
        )
        inputDevices = AudioDevices.inputDevices().map(\.name)
        launchesAtLogin = LoginItem.isEnabled
    }

    func refreshPermissions() {
        permissionsRevision &+= 1

        // The one grant that needs more than a redraw. Everything else takes
        // effect immediately; a key tap installed before this was granted
        // never delivers an event, so without this the user grants Input
        // Monitoring, watches the row tick green, and finds the trigger key
        // still does nothing -- with no reason given and no way to guess that
        // relaunching is the fix.
        //
        // The detection itself lives in the app, which also checks on becoming
        // active and on a timer: this window's poll is the fast path while it
        // happens to be open, not the only one.
        delegate?.checkPermissionGrants()
    }

    var permissionsNeedAttention: Bool {
        // Reading the counter is what ties this to the poll: SwiftUI re-runs the
        // sidebar body when it changes, and the answer below is recomputed then.
        _ = permissionsRevision
        return PermissionsState.needsSetup(for: settings)
    }

    /// The single write path. Mirrors what the menu did, so both surfaces go
    /// through the same validation.
    func change(_ mutate: (inout VerbaliseCore.Settings) -> Void) {
        guard let delegate else { return }
        var updated = delegate.currentSettings
        mutate(&updated)
        let previousDevice = delegate.currentSettings.inputDevice
        delegate.apply(settings: updated)
        refresh()

        // The meter has to follow the selection, or picking a microphone shows
        // you the level of the one you just stopped using.
        if isPreviewingInput, delegate.currentSettings.inputDevice != previousDevice {
            delegate.setInputPreview(active: false)
            delegate.setInputPreview(active: true)
        }
    }

    func download(_ model: TranscriptionModel) {
        delegate?.downloadModel(model)
        refresh()
    }

    func cancelDownload(_ model: TranscriptionModel) {
        delegate?.cancelModelDownload(model)
        refresh()
    }

    func remove(_ model: TranscriptionModel) {
        delegate?.removeModel(model)
        refresh()
    }

    func select(_ model: TranscriptionModel) {
        // Choosing a model you do not have is a request for it: the apply
        // path stages the switch, provisions the tier (download, then
        // compile), and swaps dictation over the moment it is ready. Nothing
        // extra to kick here.
        change { $0.transcriptionModel = model }
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        LoginItem.set(enabled)
        launchesAtLogin = LoginItem.isEnabled
    }

    // MARK: - Input level

    var inputPreviewMeter: LevelMeter { delegate?.inputPreview.meter ?? LevelMeter() }

    @Published private(set) var isPreviewingInput = false
    @Published private(set) var inputPreviewFailed = false

    private var previewWatcher: Task<Void, Never>?

    func startInputPreview() {
        delegate?.setInputPreview(active: true)
        inputPreviewFailed = false

        // Opening happens off the main thread and can take a moment, so the
        // first answer is usually "not yet". Watch until it settles rather than
        // asking once and leaving a dead meter on screen if CoreAudio was slow.
        previewWatcher?.cancel()
        previewWatcher = Task { [weak self] in
            for _ in 0..<15 {
                guard let self, let delegate = self.delegate else { return }
                self.isPreviewingInput = delegate.inputPreview.isRunning
                self.inputPreviewFailed = delegate.inputPreview.didFail
                if self.isPreviewingInput || self.inputPreviewFailed { return }
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
        }
    }

    func stopInputPreview() {
        previewWatcher?.cancel()
        previewWatcher = nil
        delegate?.setInputPreview(active: false)
        isPreviewingInput = false
        inputPreviewFailed = false
    }

    func flushPendingEdits() {
        pendingEdit?()
        pendingEdit = nil
    }

    func openConfigFile() { delegate?.openConfigFile() }
    func showLog() { delegate?.showLog() }
    func restart() { delegate?.restart() }
}
