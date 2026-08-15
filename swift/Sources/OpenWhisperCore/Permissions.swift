import AVFoundation
import CoreGraphics
import Foundation
import IOKit.hid

/// Ports the permission checks onto the APIs that match what the app actually
/// does. Input Monitoring and Accessibility/PostEvent are separate TCC grants.
///
/// The CoreGraphics request functions are useful for event taps, but macOS does
/// not reliably register a sandboxed app in the Input Monitoring list when they
/// are used alone. IOHIDRequestAccess is Apple's lower-level API for requesting
/// keyboard listen/post access and is the API Apple documents for this purpose.
public enum Permissions {

    // MARK: - Input Monitoring (read the trigger key)

    /// True when this app may observe key events. Does not prompt.
    public static var hasInputMonitoring: Bool {
        if #available(macOS 10.15, *) {
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
                == kIOHIDAccessTypeGranted
        }
        return true
    }

    /// Requests Input Monitoring through the HID privacy API. This also gives
    /// macOS the opportunity to register the app in the Input Monitoring list.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        if #available(macOS 10.15, *) {
            return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        return true
    }

    // MARK: - PostEvent (synthesise keystrokes)

    /// True when this app may post synthetic key events. Does not prompt.
    public static var hasPostEvent: Bool {
        if #available(macOS 10.15, *) {
            return IOHIDCheckAccess(kIOHIDRequestTypePostEvent)
                == kIOHIDAccessTypeGranted
        }
        return true
    }

    @discardableResult
    public static func requestPostEvent() -> Bool {
        if #available(macOS 10.15, *) {
            return IOHIDRequestAccess(kIOHIDRequestTypePostEvent)
        }
        return true
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

    public static func settingsURL(for pane: SettingsPane) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
    }
}
