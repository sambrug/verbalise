import AppKit
import OpenWhisperCore
import ServiceManagement

/// The menu bar item and its tree (menubar.py:719-960 is the spec).
///
/// Kept apart from AppDelegate because the menu is most of the UI surface and
/// the delegate is meant to stay a wiring layer.
@MainActor
protocol StatusMenuDelegate: AnyObject {
    var currentSettings: Settings { get }
    var currentStats: UsageStats { get }
    var currentRecent: [RecentTranscript] { get }
    var lastTranscript: String? { get }

    func apply(settings: Settings)
    func clearRecentTranscripts()
    func restart()
    func openConfigFile()
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
    private let settingsMenu = NSMenu()

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

        lastItem.isEnabled = false
        menu.addItem(lastItem)
        add(to: menu, title: "Copy Last Transcript", action: #selector(copyLast))

        let recentItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        statsItem.isEnabled = false
        menu.addItem(statsItem)
        timeSavedItem.isEnabled = false
        menu.addItem(timeSavedItem)

        menu.addItem(.separator())

        add(to: menu, title: "Permissions…", action: #selector(showPermissions))
        add(to: menu, title: "Open Config", action: #selector(openConfig))
        add(to: menu, title: "View Logs", action: #selector(viewLogs))
        add(to: menu, title: "Launch at Login", action: #selector(toggleLoginItem))
        add(to: menu, title: "Restart", action: #selector(restart))

        menu.addItem(.separator())
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
        rebuildSettings()
        refreshStatsLines()
        refreshLoginItemState()
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

    // MARK: - Settings submenu

    private func rebuildSettings() {
        settingsMenu.removeAllItems()
        guard let delegate else { return }
        let settings = delegate.currentSettings

        // Trigger key
        let triggerMenu = NSMenu()
        for key in TriggerKey.allCases {
            let item = NSMenuItem(
                title: key.displayName, action: #selector(pickTriggerKey(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = key.rawValue
            item.state = settings.triggerKey == key.rawValue ? .on : .off
            triggerMenu.addItem(item)
        }
        addSubmenu(to: settingsMenu, title: "Trigger Key", submenu: triggerMenu)

        // Model
        let modelMenu = NSMenu()
        for model in TranscriptionModel.allCases {
            let item = NSMenuItem(
                title: "\(model.displayName) — \(model.approximateDownloadSize)",
                action: #selector(pickModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model.rawValue
            item.state = settings.transcriptionModel == model ? .on : .off
            item.toolTip = model.summary
            modelMenu.addItem(item)
        }
        addSubmenu(to: settingsMenu, title: "Transcription Model", submenu: modelMenu)

        // Input device
        let deviceMenu = NSMenu()
        let systemDefault = NSMenuItem(
            title: "System Default", action: #selector(pickInputDevice(_:)), keyEquivalent: ""
        )
        systemDefault.target = self
        systemDefault.representedObject = ""
        systemDefault.state = settings.inputDevice == nil ? .on : .off
        deviceMenu.addItem(systemDefault)
        deviceMenu.addItem(.separator())
        for device in AudioDevices.inputDevices() {
            let item = NSMenuItem(
                title: device.name, action: #selector(pickInputDevice(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.name
            item.state = settings.inputDevice == device.name ? .on : .off
            deviceMenu.addItem(item)
        }
        addSubmenu(to: settingsMenu, title: "Input Device", submenu: deviceMenu)

        settingsMenu.addItem(.separator())

        // Two states, so a checkbox rather than a submenu of one real choice.
        addToggle(title: "Recording Overlay",
                  on: settings.overlayStyle == .on,
                  action: #selector(toggleOverlay))
        addToggle(title: "Streaming Transcribe",
                  on: settings.advanced.streamingTranscribeEnabled,
                  action: #selector(toggleStreaming))
        addToggle(title: "Fast Typing",
                  on: settings.advanced.fastTypingEnabled,
                  action: #selector(toggleFastTyping))
        addToggle(title: "Trim Silence",
                  on: settings.advanced.trimSilenceEnabled,
                  action: #selector(toggleTrimSilence))
        addToggle(title: "Sound Feedback",
                  on: settings.soundEnabled,
                  action: #selector(toggleSound))

        settingsMenu.addItem(.separator())

        add(to: settingsMenu, title: "Vocabulary…", action: #selector(editVocabulary))
        add(to: settingsMenu, title: "Phonetic Corrections…", action: #selector(editPhonetic))
    }

    private func addSubmenu(to menu: NSMenu, title: String, submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func addToggle(title: String, on: Bool, action: Selector) {
        let item = add(to: settingsMenu, title: title, action: action)
        item.state = on ? .on : .off
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

    // MARK: - Login item

    private var loginItem: NSMenuItem? {
        statusItem.menu?.items.first { $0.title == "Launch at Login" }
    }

    private func refreshLoginItemState() {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("login item: \(error.localizedDescription)")
            show(alert: "Could not change Launch at Login: \(error.localizedDescription)")
        }
        refreshLoginItemState()
    }

    // MARK: - Actions

    private func mutate(_ change: (inout Settings) -> Void) {
        guard let delegate else { return }
        var settings = delegate.currentSettings
        change(&settings)
        delegate.apply(settings: settings)
    }

    @objc private func pickTriggerKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        mutate { $0.triggerKey = raw }
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let model = TranscriptionModel(rawValue: raw) else { return }
        mutate { $0.transcriptionModel = model }
    }

    @objc private func pickInputDevice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        mutate { $0.inputDevice = name.isEmpty ? nil : name }
    }

    @objc private func toggleOverlay() {
        mutate { $0.overlayStyle = $0.overlayStyle == .on ? .off : .on }
    }

    @objc private func toggleStreaming() {
        mutate { $0.advanced.streamingTranscribeEnabled.toggle() }
    }

    @objc private func toggleFastTyping() {
        mutate { $0.advanced.fastTypingEnabled.toggle() }
    }

    @objc private func toggleTrimSilence() {
        mutate { $0.advanced.trimSilenceEnabled.toggle() }
    }

    @objc private func toggleSound() {
        mutate { $0.soundEnabled.toggle() }
    }

    @objc private func editVocabulary() {
        guard let delegate else { return }
        TextEditorWindow.show(
            title: "Vocabulary",
            help: "Domain terms Whisper should favour — names, acronyms, jargon. One per line.",
            text: delegate.currentSettings.vocabulary.joined(separator: "\n")
        ) { [weak self] text in
            self?.mutate {
                $0.vocabulary = text
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }
    }

    @objc private func editPhonetic() {
        guard let delegate else { return }
        let existing = delegate.currentSettings.orderedPhoneticCorrections
            .map { "\($0.misheard): \($0.correct)" }
            .joined(separator: "\n")

        TextEditorWindow.show(
            title: "Phonetic Corrections",
            help: "Stubborn mishearings, replaced whole-word after transcription. "
                + "One per line as  misheard: correct  — for example  ethanol: FNOL",
            text: existing
        ) { [weak self] text in
            var corrections: [String: String] = [:]
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !value.isEmpty else { continue }
                corrections[key] = value
            }
            self?.mutate { $0.phoneticCorrections = corrections }
        }
    }

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

    @objc private func openConfig() {
        delegate?.openConfigFile()
    }

    @objc private func viewLogs() {
        LogWindow.show()
    }

    @objc private func showPermissions() {
        OnboardingWindow.show()
    }

    @objc private func restart() {
        delegate?.restart()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
