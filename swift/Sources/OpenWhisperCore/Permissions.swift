import AVFoundation
import CoreGraphics
import Foundation

/// Ports `check_accessibility` / `check_microphone` (daemon.py:1858-1927) onto
/// the APIs that are actually correct for what this app does.
///
/// The Python app used `AXIsProcessTrusted`, which reports the Accessibility
/// grant. That is the wrong signal and is sandbox-banned besides (APP_STORE.md
/// §1): we never use AX. What we need is two separate CoreGraphics grants --
/// Input Monitoring to *observe* the trigger key, and PostEvent to *synthesise*
/// the keystrokes that insert text. They are distinct TCC records and a user
/// can grant one without the other, so they are checked and requested apart.
public enum Permissions {

    // MARK: - Input Monitoring (read the trigger key)

    /// True when this app may observe key events. Does not prompt.
    public static var hasInputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    /// Prompts for Input Monitoring if it has never been asked for.
    ///
    /// macOS shows the system prompt only once per app; afterwards this
    /// returns the standing answer and the user must change it in System
    /// Settings. Returns the grant state, not "did we prompt".
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    // MARK: - PostEvent (synthesise keystrokes)

    /// True when this app may post synthetic key events. Does not prompt.
    public static var hasPostEvent: Bool {
        CGPreflightPostEventAccess()
    }

    @discardableResult
    public static func requestPostEvent() -> Bool {
        CGRequestPostEventAccess()
    }

    // MARK: - Microphone

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static var hasMicrophone: Bool {
        microphoneStatus == .authorized
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Deep links into the exact System Settings panes

    public enum SettingsPane: String {
        case inputMonitoring = "Privacy_ListenEvent"
        case accessibility = "Privacy_Accessibility"
        case microphone = "Privacy_Microphone"
    }

    /// URL for the onboarding window's "Open System Settings" buttons.
    public static func settingsURL(for pane: SettingsPane) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
    }

    // MARK: - Whether the system prompt has already been spent

    /// macOS shows its prompt once per app identity, *ever*. Every later
    /// request returns the standing answer and displays nothing at all.
    ///
    /// That single fact drives two decisions in this app -- whether a launch
    /// can prompt (and so collide with a window we are about to open), and
    /// whether the Permissions pane's button should offer to ask or to open
    /// System Settings. Both are wrong if the answer resets when the app does,
    /// so it is recorded here rather than held in view state.
    private static let promptedKey = "PermissionsPrompted"

    public static func hasPrompted(for pane: SettingsPane) -> Bool {
        let seen = UserDefaults.standard.stringArray(forKey: promptedKey) ?? []
        return seen.contains(pane.rawValue)
    }

    public static func recordPrompted(for pane: SettingsPane) {
        var seen = UserDefaults.standard.stringArray(forKey: promptedKey) ?? []
        guard !seen.contains(pane.rawValue) else { return }
        seen.append(pane.rawValue)
        UserDefaults.standard.set(seen, forKey: promptedKey)
    }
}
