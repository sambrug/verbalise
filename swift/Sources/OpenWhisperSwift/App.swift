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

        // Opens a capture stream exactly as a dictation would, records briefly,
        // and reports what arrived. Reproduces the audio path without needing a
        // keypress, so a failure in it prints its own exception rather than
        // only leaving a crash report behind.
        if CommandLine.arguments.contains("--test-capture") {
            testCapture()
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
                case .preparing:
                    print("  preparing for first use (compiling for the Neural Engine — "
                          + "this can take several minutes)…")
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

    private static func testCapture() {
        let settings = SettingsStore()?.load().settings ?? Settings()
        print("Opening capture at \(settings.sampleRate)Hz, device=\(settings.inputDevice ?? "system default")")

        // Mirror the app: it pre-warms at launch, so a real dictation is
        // always the *second* stream this process opens.
        if CommandLine.arguments.contains("--prewarm-first") {
            print("Pre-warming…")
            AudioPrewarm.run(sampleRate: Double(settings.sampleRate))
            print("Pre-warm returned.")
        }

        let counter = SampleCounter()
        let opener = AVAudioCaptureOpener(
            sampleRate: Double(settings.sampleRate),
            deviceName: settings.inputDevice,
            onSamples: { counter.add($0.count) }
        )

        do {
            let stream = try opener.open()
            // The opener returns an unstarted stream; the caller starts it,
            // exactly as DictationController does.
            try stream.start()
            print("Stream opened and started. Recording 2s…")
            Thread.sleep(forTimeInterval: 2)
            print("Received \(counter.total) samples "
                  + "(~\(String(format: "%.2f", Double(counter.total) / Double(settings.sampleRate)))s)")
            stream.abort()
            stream.close()
            print("Stream closed cleanly.")
        } catch {
            print("FAILED to open: \(error)")
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

/// Counts samples delivered from the realtime audio thread.
private final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func add(_ n: Int) {
        lock.lock(); count += n; lock.unlock()
    }
}
