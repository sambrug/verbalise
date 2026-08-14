import AppKit
import OpenWhisperCore

/// Menu bar accessory: no Dock icon, no main window, no storyboard.
/// `LSUIElement` in Info.plist does the same job for a launched bundle; setting
/// the activation policy here keeps `swift run` behaving the same way.
@main
enum OpenWhisperApp {
    @MainActor
    static func main() {
        // Support-oriented flags, handled before any UI comes up. "Which
        // devices can it actually see" is the first question when a
        // configured microphone stops working, and answering it should not
        // require launching the app and reading a log.
        if CommandLine.arguments.contains("--list-devices") {
            listDevices()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)

        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    private static func listDevices() {
        let devices = AudioDevices.inputDevices()
        let defaultDevice = AudioDevices.defaultInputDevice()

        guard !devices.isEmpty else {
            print("No audio input devices found.")
            return
        }
        print("Audio input devices (\(devices.count)):")
        for device in devices {
            let marker = device.id == defaultDevice?.id ? " (system default)" : ""
            print("  \(device.name)\(marker)")
        }
        print("\nUse the exact name as `input_device` in config.json.")
    }
}
