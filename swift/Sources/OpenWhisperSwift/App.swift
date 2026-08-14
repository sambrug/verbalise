import AppKit
import OpenWhisperCore
import OpenWhisperSpeech

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

        // Downloads and loads the configured model, then exits. Two uses:
        // pre-fetching before an App Store archive (plan §4), and proving the
        // sandboxed network path works without having to discover a failure
        // part-way through someone's first dictation.
        if CommandLine.arguments.contains("--warm-model") {
            warmModel()
            return
        }

        // Lets Scripts/fetch-default-model.sh find the folder to stage without
        // duplicating the mapping in shell, where it would silently drift.
        if CommandLine.arguments.contains("--print-bundled-variant") {
            print(TranscriptionModel.bundled.whisperKitModelName)
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

    private static func warmModel() {
        let settings = SettingsStore()?.load().settings ?? Settings()
        let variant = settings.transcriptionModel.whisperKitModelName
        print("Warming \(settings.transcriptionModel.displayName) (\(variant), "
              + "~\(settings.transcriptionModel.approximateDownloadSize))…")

        let done = DispatchSemaphore(value: 0)
        let outcome = ErrorBox()

        Task.detached {
            defer { done.signal() }
            let engine = TranscriptionEngine(settings: settings) { phase in
                switch phase {
                case .downloading(let fraction):
                    if let fraction {
                        print(String(format: "  downloading %.0f%%", fraction * 100))
                    } else {
                        print("  downloading…")
                    }
                case .loading: print("  loading…")
                case .ready: print("  ready")
                case .idle: break
                }
            }
            do {
                try await engine.ensureLoaded()
            } catch {
                outcome.set(error)
            }
        }
        done.wait()

        if let failure = outcome.value {
            print("FAILED: \(failure.localizedDescription)")
        } else {
            print("Model is downloaded and loads. Storage: container Application Support/Models.")
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

/// Carries an error out of a detached Task to a semaphore-blocked caller.
/// Only used by the one-shot command-line flags, which have no run loop.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any Error)?

    var value: (any Error)? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ error: any Error) {
        lock.lock(); stored = error; lock.unlock()
    }
}
