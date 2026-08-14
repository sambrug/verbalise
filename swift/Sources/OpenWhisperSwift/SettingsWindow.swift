import AppKit
import Combine
import OpenWhisperCore
import SwiftUI

/// What the Settings window needs from the app.
///
/// Deliberately not `StatusMenuDelegate` widened: the menu now shows state and
/// the window now owns configuration, and giving each the surface it actually
/// uses is what keeps that split honest.
@MainActor
protocol SettingsDelegate: AnyObject {
    var currentSettings: OpenWhisperCore.Settings { get }
    func apply(settings: OpenWhisperCore.Settings)

    var downloadedModels: Set<TranscriptionModel> { get }
    var modelDownloads: [TranscriptionModel: Double?] { get }
    func downloadModel(_ model: TranscriptionModel)
    func cancelModelDownload(_ model: TranscriptionModel)

    func openConfigFile()
    func importFromPythonApp()
    func showLog()
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
        existing.window.makeKeyAndOrderFront(nil)
        if !existing.window.isVisible { existing.window.center() }
        existing.startPollingPermissions()
    }

    /// First run, and any later run where a grant has been revoked.
    ///
    /// Replaces the separate onboarding window: the permission rows now live in
    /// the pane that also explains the rest of the app, so there is one place to
    /// send someone rather than two that overlap.
    static func showIfPermissionsMissing(delegate: any SettingsDelegate) {
        guard PermissionsState.needsSetup else { return }
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
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        // A settings window is not resizable in System Settings either; the two
        // columns have one correct width each and nothing gains from dragging.
        window.setContentSize(NSSize(width: 720, height: 480))
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
        // Anything still sitting in a debounce is written now rather than lost.
        model.flushPendingEdits()
    }
}

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case triggerKey
    case speechModel
    case audio
    case textOutput
    case vocabulary
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .triggerKey: "Trigger key"
        case .speechModel: "Speech model"
        case .audio: "Audio"
        case .textOutput: "Text output"
        case .vocabulary: "Vocabulary"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "switch.2"
        case .triggerKey: "keyboard.fill"
        case .speechModel: "sparkles"
        case .audio: "mic.fill"
        case .textOutput: "text.cursor"
        case .vocabulary: "book.fill"
        case .permissions: "lock.fill"
        }
    }

    /// The tinted rounded square System Settings puts beside every row.
    var tint: Color {
        switch self {
        case .general: .gray
        case .triggerKey: .indigo
        case .speechModel: .purple
        case .audio: .orange
        case .textOutput: .blue
        case .vocabulary: .brown
        case .permissions: .secondary
        }
    }
}

/// The three TCC grants, read together.
enum PermissionsState {
    static var needsSetup: Bool {
        !Permissions.hasInputMonitoring
            || !Permissions.hasPostEvent
            || !Permissions.hasMicrophone
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
    @Published private(set) var settings: OpenWhisperCore.Settings
    @Published private(set) var rows: [ModelRow] = []
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
        rows = ModelCatalog.rows(
            selected: settings.transcriptionModel,
            downloaded: delegate.downloadedModels,
            downloading: delegate.modelDownloads
        )
        inputDevices = AudioDevices.inputDevices().map(\.name)
        launchesAtLogin = LoginItem.isEnabled
    }

    func refreshPermissions() {
        permissionsRevision &+= 1
    }

    var permissionsNeedAttention: Bool {
        // Reading the counter is what ties this to the poll: SwiftUI re-runs the
        // sidebar body when it changes, and the answer below is recomputed then.
        _ = permissionsRevision
        return PermissionsState.needsSetup
    }

    /// The single write path. Mirrors what the menu did, so both surfaces go
    /// through the same validation.
    func change(_ mutate: (inout OpenWhisperCore.Settings) -> Void) {
        guard let delegate else { return }
        var updated = delegate.currentSettings
        mutate(&updated)
        delegate.apply(settings: updated)
        refresh()
    }

    func download(_ model: TranscriptionModel) {
        delegate?.downloadModel(model)
        refresh()
    }

    func cancelDownload(_ model: TranscriptionModel) {
        delegate?.cancelModelDownload(model)
        refresh()
    }

    func select(_ model: TranscriptionModel) {
        change { $0.transcriptionModel = model }
        // Choosing a model you do not have is a request for it. Without this the
        // row would sit at "not downloaded" while the engine quietly fetched it
        // on the next dictation, which is the hang this pane exists to make
        // visible.
        if !(delegate?.downloadedModels.contains(model) ?? true) {
            download(model)
        }
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        LoginItem.set(enabled)
        launchesAtLogin = LoginItem.isEnabled
    }

    func flushPendingEdits() {
        pendingEdit?()
        pendingEdit = nil
    }

    func openConfigFile() { delegate?.openConfigFile() }
    func importFromPython() { delegate?.importFromPythonApp() }
    func showLog() { delegate?.showLog() }
}
