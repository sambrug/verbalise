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

    /// Requests Input Monitoring. If macOS has already consumed its one-time
    /// prompt for this app, open the exact System Settings pane instead of
    /// leaving the user staring at a button that appears to do nothing.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        let granted = CGRequestListenEventAccess()
        if !granted, !hasInputMonitoring {
            openSystemSettings(for: .inputMonitoring)
        }
        return granted
    }

    // MARK: - PostEvent (synthesise keystrokes)

    /// True when this app may post synthetic key events. Does not prompt.
    public static var hasPostEvent: Bool {
        CGPreflightPostEventAccess()
    }

    @discardableResult
    public static func requestPostEvent() -> Bool {
        let granted = CGRequestPostEventAccess()
        if !granted, !hasPostEvent {
            openSystemSettings(for: .accessibility)
        }
        return granted
    }

    // MARK: - Microphone

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static var hasMicrophone: Bool {
        microphoneStatus == .authorized
    }

    public static func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if !granted, !hasMicrophone {
            openSystemSettings(for: .microphone)
        }
        return granted
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

    /// Opens the relevant privacy pane. Kept here so every permission request
    /// follows the same fallback behaviour and callers do not need to know the
    /// System Settings URL scheme.
    private static func openSystemSettings(for pane: SettingsPane) {
        guard let url = settingsURL(for: pane) else { return }
        NSWorkspace.shared.open(url)
    }
}
