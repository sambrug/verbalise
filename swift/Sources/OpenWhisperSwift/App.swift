import AppKit

/// Menu bar accessory: no Dock icon, no main window, no storyboard.
/// `LSUIElement` in Info.plist does the same job for a launched bundle; setting
/// the activation policy here keeps `swift run` behaving the same way.
@main
enum OpenWhisperApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)

        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
