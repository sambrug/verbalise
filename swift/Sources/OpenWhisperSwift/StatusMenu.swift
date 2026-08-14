import AppKit
import OpenWhisperCore

/// The menu bar item and its tree (menubar.py:719-960 is the spec).
///
/// Kept apart from AppDelegate because the menu is most of the UI surface and
/// the delegate is meant to stay a wiring layer.
@MainActor
protocol StatusMenuDelegate: AnyObject {
    var currentStats: UsageStats { get }
    var currentRecent: [RecentTranscript] { get }
    var lastTranscript: String? { get }

    func clearRecentTranscripts()
    func showSettings()
    func restart()
}

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private weak var delegate: (any StatusMenuDelegate)?

    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let alertItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastItem = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
    private let statsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let timeSavedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let recentMenu = NSMenu()

    /// Persistent alert shown as a scrolling line (menubar.py:1022). Cleared
    /// when the next dictation succeeds.
    private var alert: String?
    private var marqueeTimer: Timer?
    private var marqueeOffset = 0

    private var dictationCount = 0

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
            systemSymbolName: "waveform", accessibilityDescription: "Open Whisper Swift"
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

        alertItem.isEnabled = false
        alertItem.isHidden = true
        menu.addItem(alertItem)

        menu.addItem(.separator())

        // The transcript itself copies on click — a separate "Copy Last"
        // item was a second row saying what clicking the first should
        // obviously do.
        lastItem.target = self
        lastItem.action = #selector(copyLast)
        lastItem.toolTip = "Click to copy"
        menu.addItem(lastItem)

        let recentItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        // Everything configurable lives in the Settings window. Only what you
        // act on in the moment — state, the last transcript, Restart, Quit —
        // stays here. A submenu could not show a model downloading, could not
        // hold the permission rows, and made every toggle a four-level hover.
        add(to: menu, title: "Settings…", action: #selector(showSettings), key: ",")

        menu.addItem(.separator())

        statsItem.isEnabled = false
        menu.addItem(statsItem)
        timeSavedItem.isEnabled = false
        menu.addItem(timeSavedItem)

        menu.addItem(.separator())

        add(to: menu, title: "Restart", action: #selector(restart))
        add(to: menu, title: "Quit Open Whisper Swift", action: #selector(quit), key: "q")

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
        refreshStatsLines()
    }

    func show(state: DictationState) {
        switch state {
        case .idle: stateItem.title = badged("Ready")
        case .recording: stateItem.title = badged("Recording…")
        case .transcribing: stateItem.title = badged("Transcribing…")
        }
    }

    func show(status: String) {
        stateItem.title = badged(status)
    }

    /// The count badge from menubar.py's status line.
    private func badged(_ text: String) -> String {
        dictationCount > 0 ? "\(text)  (\(dictationCount))" : text
    }

    func noteDictationCompleted() {
        dictationCount += 1
        // A successful dictation means whatever the alert warned about is
        // no longer happening.
        clearAlert()
    }

    func show(lastTranscript text: String) {
        lastItem.title = "“\(Self.truncate(text))”"
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

    /// A persistent alert scrolls, because the menu bar has no room for the
    /// full text and a truncated warning tells the user nothing.
    func show(alert message: String) {
        alert = message
        alertItem.isHidden = false
        marqueeOffset = 0
        marqueeTimer?.invalidate()
        marqueeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.tickMarquee() }
        }
        tickMarquee()
    }

    func clearAlert() {
        alert = nil
        alertItem.isHidden = true
        marqueeTimer?.invalidate()
        marqueeTimer = nil
    }

    private func tickMarquee() {
        guard let alert else { return }
        let width = 38
        guard alert.count > width else {
            alertItem.title = "⚠︎ \(alert)"
            return
        }
        let padded = Array(alert + "   •   ")
        let start = marqueeOffset % padded.count
        let window = (0..<width).map { padded[(start + $0) % padded.count] }
        alertItem.title = "⚠︎ " + String(window)
        marqueeOffset += 1
    }

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
            let time = entry.ts.split(separator: "T").last.map(String.init) ?? entry.ts
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

    private func refreshStatsLines() {
        let stats = delegate?.currentStats ?? UsageStats()
        statsItem.title = StatsFormatter.formatStats(stats)
        if let saved = StatsFormatter.formatTimeSaved(stats) {
            timeSavedItem.title = saved
            timeSavedItem.isHidden = false
        } else {
            timeSavedItem.isHidden = true
        }
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

    @objc private func restart() {
        delegate?.restart()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
