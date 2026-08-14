import AppKit
import OpenWhisperCore

/// A plain multiline text editor with Save and Cancel.
///
/// This exists as a real window rather than an alert accessory because the
/// Python could not do it: rumps had no text-entry surface, so menubar.py:374
/// hand-built one and lost working Cmd+C/V/X/A in the process. An NSTextView
/// in a key window gets the standard editing commands from the responder chain
/// for free — but only if the window can *become* key, which for an accessory
/// app means activating first.
@MainActor
final class TextEditorWindow: NSObject, NSWindowDelegate {

    /// Windows are retained here because nothing else holds them; without this
    /// the window deallocates the moment the function returns.
    private static var open: Set<TextEditorWindow> = []

    private let window: NSWindow
    private let textView: NSTextView
    private let onSave: (String) -> Void

    static func show(
        title: String,
        help: String,
        text: String,
        onSave: @escaping (String) -> Void
    ) {
        let editor = TextEditorWindow(title: title, help: help, text: text, onSave: onSave)
        open.insert(editor)
        NSApp.activate(ignoringOtherApps: true)
        editor.window.makeKeyAndOrderFront(nil)
        editor.window.center()
    }

    private init(title: String, help: String, text: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false

        let helpLabel = NSTextField(labelWithString: help)
        helpLabel.font = .systemFont(ofSize: 11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.preferredMaxLayoutWidth = 480

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        textView = NSTextView()
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        // Smart dashes would rewrite a hyphen in a vocabulary term.
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.autoresizingMask = [.width]
        scroll.documentView = textView

        let save = NSButton(title: "Save", target: nil, action: nil)
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"

        super.init()

        save.target = self
        save.action = #selector(saveTapped)
        cancel.target = self
        cancel.action = #selector(cancelTapped)

        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [helpLabel, scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        buttons.setContentHuggingPriority(.defaultHigh, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false

        window.contentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.delegate = self
        window.initialFirstResponder = textView
    }

    @objc private func saveTapped() {
        onSave(textView.string)
        close()
    }

    @objc private func cancelTapped() {
        close()
    }

    private func close() {
        window.orderOut(nil)
        Self.open.remove(self)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(self)
    }
}

/// The in-app log viewer.
///
/// Replaces the Python's "View Logs", which shelled out to Terminal via
/// osascript (menubar.py:1629) — sandbox-illegal, and it opened a terminal the
/// user then had to close.
@MainActor
final class LogWindow: NSObject, NSWindowDelegate {

    private static var shared: LogWindow?

    private let window: NSWindow
    private let textView: NSTextView
    private var timer: Timer?

    static func show() {
        let existing = shared ?? LogWindow()
        shared = existing
        NSApp.activate(ignoringOtherApps: true)
        existing.window.makeKeyAndOrderFront(nil)
        existing.refresh()
        existing.startTailing()
    }

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Open Whisper Log"
        window.isReleasedWhenClosed = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false

        textView = NSTextView()
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView

        window.contentView = scroll
        super.init()
        window.delegate = self
    }

    private func startTailing() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                LogWindow.shared?.refresh()
            }
        }
    }

    private func refresh() {
        guard let url = Log.shared.logFileURL,
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        // Only the tail. A long-lived install accumulates a log far larger
        // than anyone wants rendered into a text view.
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(2000).joined(separator: "\n")
        guard tail != textView.string else { return }

        textView.string = tail
        textView.scrollToEndOfDocument(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
