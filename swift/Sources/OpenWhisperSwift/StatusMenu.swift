import AppKit
import OpenWhisperCore

/// The menu bar item and its tree (menubar.py:719-960 is the spec).
///
/// Kept apart from AppDelegate because the menu is most of the UI surface and
/// the delegate is meant to stay a wiring layer.
@MainActor
protocol StatusMenuDelegate: AnyObject {
    var currentRecent: [RecentTranscript] { get }
    var lastTranscript: String? { get }

    func clearRecentTranscripts()
    func showSettings()
}

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private weak var delegate: (any StatusMenuDelegate)?

    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let alertItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastItem = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
    private let recentMenu = NSMenu()

    /// Persistent alert (menubar.py:1022). Cleared when the next dictation
    /// succeeds.
    private var alert: String?

    /// The product name, from the bundle, so the menu cannot drift from what
    /// Finder and the About panel call it.
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Open Whisper"
    }

    init(delegate: any StatusMenuDelegate) {
        self.delegate = delegate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Deliberately not the Python app's icon (menubar.py:334) so the two
        // are tellable apart at a glance while both are installed.
        //
        // The point size matters: an SF Symbol at its default size renders
        // noticeably smaller than the system's own menu bar glyphs, which made
        // it look shrunken next to them. 16pt matches their optical weight.
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let icon = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: Self.appName
        )?.withSymbolConfiguration(configuration)
        icon?.isTemplate = true
        statusItem.button?.image = icon

        build()
    }

    // MARK: - Building

    private func build() {
        let menu = NSMenu()
        menu.delegate = self

        stateItem.isEnabled = false
        menu.addItem(stateItem)

        // Clickable, because every message it carries is answered somewhere in
        // Settings -- a bad trigger key, a model still downloading, an audio
        // system that needs the app restarted. Making the warning the way in
        // costs nothing and saves reading it, dismissing it, and hunting.
        alertItem.target = self
        alertItem.action = #selector(showSettings)
        alertItem.isHidden = true
        menu.addItem(alertItem)

        menu.addItem(.separator())

        // The transcript itself copies on click — a separate "Copy Last"
        // item was a second row saying what clicking the first should
        // obviously do.
        lastItem.target = self
        lastItem.action = #selector(copyLast)
        lastItem.toolTip = "Click to copy"
        // Nothing to copy yet, so nothing to click. Enabled the moment a
        // transcript arrives.
        lastItem.isEnabled = false
        menu.addItem(lastItem)

        let recentItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        // Everything configurable lives in the Settings window. Only what you
        // act on in the moment — state, the last transcript, Quit — stays
        // here. A submenu could not show a model downloading, could not hold
        // the permission rows, and made every toggle a four-level hover.
        add(to: menu, title: "Settings…", action: #selector(showSettings), key: ",")

        menu.addItem(.separator())

        add(to: menu, title: "About \(Self.appName)", action: #selector(showAbout))
        add(to: menu, title: "Quit \(Self.appName)", action: #selector(quit), key: "q")

        statusItem.menu = menu
    }

    @discardableResult
    private func add(
        to menu: NSMenu, title: String, action: Selector, key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Refresh

    func menuWillOpen(_ menu: NSMenu) {
        rebuildRecent()
    }

    func show(state: DictationState) {
        switch state {
        case .idle: stateItem.title = "Ready"
        case .recording: stateItem.title = "Recording…"
        case .transcribing: stateItem.title = "Transcribing…"
        }
    }

    func show(status: String) {
        stateItem.title = status
    }

    func noteDictationCompleted() {
        // A successful dictation means whatever the alert warned about is
        // no longer happening.
        clearAlert()
    }

    func show(lastTranscript text: String) {
        lastItem.title = "“\(Self.truncate(text))”"
        lastItem.isEnabled = true
    }

    /// Truncates on a word boundary rather than mid-word (menubar.py's
    /// "truncated smart").
    static func truncate(_ text: String, limit: Int = 48) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }

        let clipped = collapsed.prefix(limit)
        if let lastSpace = clipped.lastIndex(of: " "), lastSpace > clipped.startIndex {
            return clipped[..<lastSpace] + "…"
        }
        return clipped + "…"
    }

    // MARK: - Alerts

    /// One truncated line with a warning symbol, and the full text on hover.
    ///
    /// This replaces a marquee. The Python scrolled the message a character at
    /// a time because a menu bar has no room for a long warning -- but nothing
    /// on macOS scrolls text at you, it is hard to read at any speed, and it
    /// animates forever in a menu the user is not looking at. Truncating with
    /// the whole message in the tooltip is what the platform does, and the
    /// alerts worth showing lead with their point anyway.
    func show(alert message: String) {
        self.alert = message
        alertItem.title = Self.truncate(message, limit: 44)
        alertItem.toolTip = "\(message)\n\nClick to open Settings."

        alertItem.image = Self.warningSymbol
        alertItem.isHidden = false
    }

    func clearAlert() {
        alert = nil
        alertItem.isHidden = true
        alertItem.toolTip = nil
    }

    /// A real symbol rather than a "⚠︎" in the title string: it picks up the
    /// menu's own tinting and stays aligned with the text baseline.
    private static let warningSymbol: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(.init(paletteColors: [.systemOrange]))
        return NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Warning"
        )?.withSymbolConfiguration(configuration)
    }()

    // MARK: - Recent transcripts

    private func rebuildRecent() {
        recentMenu.removeAllItems()
        let recent = delegate?.currentRecent ?? []

        guard !recent.isEmpty else {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }

        for (index, entry) in recent.enumerated() {
            let time = entry.date?.formatted(date: .omitted, time: .shortened)
                ?? entry.ts
            let item = NSMenuItem(
                title: "\(time)  \(Self.truncate(entry.text, limit: 44))",
                action: #selector(copyRecent(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.toolTip = entry.text
            recentMenu.addItem(item)
        }

        recentMenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear", action: #selector(clearRecent), keyEquivalent: "")
        clear.target = self
        recentMenu.addItem(clear)
    }

    // MARK: - Actions

    @objc private func copyLast() {
        guard let text = delegate?.lastTranscript else { return }
        SystemPasteboard().write(text)
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let recent = delegate?.currentRecent, sender.tag < recent.count else { return }
        SystemPasteboard().write(recent[sender.tag].text)
    }

    @objc private func clearRecent() {
        delegate?.clearRecentTranscripts()
    }

    @objc private func showSettings() {
        delegate?.showSettings()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Dictation that runs entirely on this Mac.\n"
                    + "Nothing you say is sent to a server.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
