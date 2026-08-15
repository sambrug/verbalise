import AppKit
import VerbaliseCore

/// The in-app log viewer.
///
/// Replaces the Python's "View Logs", which shelled out to Terminal via
/// osascript (legacy-python/menubar.py:1629) — sandbox-illegal, and it opened a terminal the
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
        window.title = "Verbalise Log"
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
