import AppKit
import OpenWhisperCore

/// Phase 1 shell. Its whole job is to prove the thesis in APP_STORE.md §1:
/// that a sandboxed app can both *observe* the trigger key (Input Monitoring)
/// and *synthesise* keystrokes into another app (PostEvent). If either fails
/// here, nothing else in the plan is worth building.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var keyTap: KeyTap?
    private let keyboard = SystemKeyboard()

    /// Phase 1 hardcodes the default; Phase 2's Settings model takes over.
    private let combo = TriggerCombo(keys: [.shiftR])

    private var statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("Open Whisper (Swift) launched — sandbox proof build")
        log("bundle: \(Bundle.main.bundleIdentifier ?? "none")")
        log("input monitoring: \(Permissions.hasInputMonitoring), post event: \(Permissions.hasPostEvent)")

        buildStatusItem()
        startKeyTap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyTap?.stop()
        log("Open Whisper (Swift) terminating")
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Deliberately not the Python app's icon (menubar.py:334) so the two
        // are tellable apart at a glance while both are installed.
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Open Whisper Swift"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Type “hello from swift”",
                     action: #selector(typeHello),
                     keyEquivalent: "").target = self

        menu.addItem(.separator())

        menu.addItem(withTitle: "Grant Input Monitoring…",
                     action: #selector(grantInputMonitoring),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Grant Keystroke Posting…",
                     action: #selector(grantPostEvent),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Grant Microphone…",
                     action: #selector(grantMicrophone),
                     keyEquivalent: "").target = self

        menu.addItem(.separator())

        menu.addItem(withTitle: "Reveal Log File",
                     action: #selector(revealLog),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Open Whisper Swift",
                     action: #selector(quit),
                     keyEquivalent: "q").target = self

        item.menu = menu
        statusItem = item
        refreshStatusLine()
    }

    private func refreshStatusLine() {
        let listen = Permissions.hasInputMonitoring ? "on" : "OFF"
        let post = Permissions.hasPostEvent ? "on" : "OFF"
        let tap = keyTap == nil ? "not installed" : "installed"
        statusLine.title = "Listen \(listen) · Post \(post) · Tap \(tap)"
    }

    // MARK: - Key tap

    private func startKeyTap() {
        // Ask before installing: tapCreate simply fails without the grant, and
        // failing silently at launch is exactly the "silent hang" the plan is
        // trying to design out.
        if !Permissions.hasInputMonitoring {
            log("requesting Input Monitoring…")
            Permissions.requestInputMonitoring()
        }

        let tap = KeyTap(combo: combo) { [weak self] held in
            self?.triggerChanged(held: held)
        }
        keyTap = tap.start() ? tap : nil
        refreshStatusLine()
    }

    private func triggerChanged(held: Bool) {
        log("trigger \(combo.configValue) \(held ? "DOWN" : "UP")")
    }

    // MARK: - Actions

    @objc private func typeHello() {
        guard Permissions.hasPostEvent else {
            log("cannot type: PostEvent not granted")
            Permissions.requestPostEvent()
            return
        }
        // Give the user a moment to focus the target app, since clicking the
        // menu item necessarily takes focus away from it.
        log("typing test string in 3s — focus a text field now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [keyboard] in
            keyboard.typeUnicode("hello from swift")
            log("typed test string")
        }
    }

    @objc private func grantInputMonitoring() {
        if !Permissions.requestInputMonitoring(),
           let url = Permissions.settingsURL(for: .inputMonitoring) {
            NSWorkspace.shared.open(url)
        }
        // The grant may land after the tap failed at launch; retry now.
        if keyTap == nil { startKeyTap() }
        refreshStatusLine()
    }

    @objc private func grantPostEvent() {
        if !Permissions.requestPostEvent(),
           let url = Permissions.settingsURL(for: .accessibility) {
            NSWorkspace.shared.open(url)
        }
        refreshStatusLine()
    }

    @objc private func grantMicrophone() {
        Task {
            let granted = await Permissions.requestMicrophone()
            log("microphone granted: \(granted)")
            if !granted, let url = Permissions.settingsURL(for: .microphone) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func revealLog() {
        guard let url = Log.shared.logFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusLine()
    }
}
