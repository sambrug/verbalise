import AppKit
import OpenWhisperCore

/// First-run permission setup (plan §4, required by APP_STORE.md §6).
///
/// Three separate TCC grants, none of which the app can give itself, and two of
/// which live in different System Settings panes. Without this the failure mode
/// is silent: the app launches, the trigger key does nothing, and nothing
/// explains why. That is precisely what the Python app did.
///
/// Each row polls its own preflight and updates as the grant lands, so the user
/// can leave this open beside System Settings and watch it tick over rather
/// than guessing whether a click took effect.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {

    private static var shared: OnboardingWindow?

    /// Shows only when something is actually missing.
    ///
    /// Deliberately not gated on "first run": a permission revoked later leaves
    /// the app just as broken, and the same window is the right answer then.
    static func showIfNeeded() {
        guard needsSetup else { return }
        show()
    }

    static var needsSetup: Bool {
        !Permissions.hasInputMonitoring
            || !Permissions.hasPostEvent
            || !Permissions.hasMicrophone
    }

    static func show() {
        let window = shared ?? OnboardingWindow()
        shared = window
        NSApp.activate(ignoringOtherApps: true)
        window.window.makeKeyAndOrderFront(nil)
        window.window.center()
        window.startPolling()
    }

    private let window: NSWindow
    private var rows: [PermissionRow] = []
    private let doneButton = NSButton(title: "Start Dictating", target: nil, action: nil)
    private var timer: Timer?

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Open Whisper"
        window.isReleasedWhenClosed = false
        super.init()

        let heading = NSTextField(labelWithString: "Open Whisper needs three permissions")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let subheading = NSTextField(wrappingLabelWithString:
            "macOS grants each of these separately, and none can be granted by the app itself. "
            + "This window updates as you grant them.")
        subheading.font = .systemFont(ofSize: 11)
        subheading.textColor = .secondaryLabelColor

        rows = [
            PermissionRow(
                title: "Microphone",
                detail: "Records your voice while you hold the trigger key.",
                isGranted: { Permissions.hasMicrophone },
                grant: { completion in
                    Task {
                        _ = await Permissions.requestMicrophone()
                        completion()
                    }
                },
                settingsPane: .microphone
            ),
            PermissionRow(
                title: "Input Monitoring",
                detail: "Lets Open Whisper notice the trigger key being held. "
                    + "It only watches for that key and never blocks it.",
                isGranted: { Permissions.hasInputMonitoring },
                grant: { completion in
                    Permissions.requestInputMonitoring()
                    completion()
                },
                settingsPane: .inputMonitoring
            ),
            PermissionRow(
                title: "Accessibility",
                detail: "Lets Open Whisper type the transcribed text into the app you are using.",
                isGranted: { Permissions.hasPostEvent },
                grant: { completion in
                    Permissions.requestPostEvent()
                    completion()
                },
                settingsPane: .accessibility
            ),
        ]

        doneButton.target = self
        doneButton.action = #selector(finish)
        doneButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [doneButton])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [heading, subheading] + rows.map(\.view) + [footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        window.contentView = stack
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            ])
        }
        window.delegate = self
        refresh()
    }

    private func startPolling() {
        timer?.invalidate()
        // There is no notification for a TCC change, so polling is the only
        // way to react to a grant made in System Settings.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { OnboardingWindow.shared?.refresh() }
        }
    }

    private func refresh() {
        for row in rows { row.refresh() }
        let allGranted = !Self.needsSetup
        doneButton.title = allGranted ? "Start Dictating" : "Continue Without All Permissions"
        doneButton.keyEquivalent = allGranted ? "\r" : ""
    }

    @objc private func finish() {
        window.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

/// One permission: status dot, explanation, and a button that either prompts or
/// opens the right pane.
@MainActor
private final class PermissionRow: NSObject {

    let view: NSStackView

    private let statusLabel = NSTextField(labelWithString: "○")
    private let button = NSButton(title: "Grant", target: nil, action: nil)
    private let isGranted: () -> Bool
    private let grant: (@escaping () -> Void) -> Void
    private let settingsPane: Permissions.SettingsPane

    /// macOS shows a TCC prompt only once per app. After that the request call
    /// returns the standing answer without showing anything, so a button that
    /// only ever prompts looks broken. Once asked, it opens System Settings
    /// instead.
    private var hasPrompted = false

    init(
        title: String,
        detail: String,
        isGranted: @escaping () -> Bool,
        grant: @escaping (@escaping () -> Void) -> Void,
        settingsPane: Permissions.SettingsPane
    ) {
        self.isGranted = isGranted
        self.grant = grant
        self.settingsPane = settingsPane

        statusLabel.font = .systemFont(ofSize: 15)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 360

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        view = NSStackView(views: [statusLabel, text, button])
        view.orientation = .horizontal
        view.alignment = .top
        view.spacing = 10

        super.init()
        button.target = self
        button.action = #selector(tapped)
        refresh()
    }

    func refresh() {
        let granted = isGranted()
        statusLabel.stringValue = granted ? "✓" : "○"
        statusLabel.textColor = granted ? .systemGreen : .tertiaryLabelColor
        button.isHidden = granted
        button.title = hasPrompted ? "Open Settings" : "Grant"
    }

    @objc private func tapped() {
        if hasPrompted {
            if let url = Permissions.settingsURL(for: settingsPane) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        hasPrompted = true
        grant { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
}
