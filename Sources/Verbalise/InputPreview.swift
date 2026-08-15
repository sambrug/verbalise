import Foundation
import VerbaliseCore

/// A capture stream opened purely to drive the input level meter in Settings.
///
/// The meter needs live audio, and nothing is capturing while someone is just
/// looking at the pane -- so this opens the microphone for as long as that pane
/// is on screen, exactly as System Settings' own Sound pane does. macOS shows
/// its recording indicator while it runs, which is correct and worth not hiding.
///
/// Three things it is careful about:
///
///  * **It never runs during a dictation.** Two engines on one device is
///    needless risk against the one path that must not break, so the preview
///    stops the moment the trigger key goes down and does not start while a
///    dictation is in flight.
///  * **It never blocks the main thread.** `open()` and `close()` on a wedged
///    CoreAudio can block for a long time -- the hazard the whole `Bounded`
///    design exists for -- so both happen off the main actor. A stuck
///    microphone must not freeze the Settings window.
///  * **It abandons work it no longer wants.** Leaving the pane while a stream
///    is still opening bumps a generation counter, and the stream that
///    eventually arrives is closed rather than left running with nothing
///    watching it. Same pattern, and same reason, as `DictationController`.
@MainActor
final class InputPreview {

    /// Fed from the audio thread, sampled by the view on its own timer.
    let meter = LevelMeter()

    /// True once an attempt has failed, so the pane can say "couldn't open the
    /// microphone" rather than showing a meter that sits flat and looks like
    /// silence.
    private(set) var didFail = false

    private var stream: (any AudioStream)?
    private var generation = 0

    var isRunning: Bool { stream != nil }

    func start(sampleRate: Int, deviceName: String?) {
        guard stream == nil else { return }

        generation += 1
        let generation = self.generation
        didFail = false

        let opener = AVAudioCaptureOpener(
            sampleRate: Double(sampleRate),
            deviceName: deviceName,
            // The samples themselves are of no interest; only their loudness
            // is, and that arrives on the level callback.
            onSamples: { _ in },
            onLevel: { [meter] level in meter.report(level) }
        )

        Task.detached(priority: .userInitiated) {
            do {
                // The opener hands back an unstarted stream on purpose; the
                // caller starts it. Starting it here and again elsewhere is the
                // crash this app has already had once.
                let stream = try opener.open()
                try stream.start()
                await MainActor.run { self.adopt(stream, from: generation) }
            } catch {
                log("mic preview: could not open — \(error.localizedDescription)")
                await MainActor.run { self.noteFailure(from: generation) }
            }
        }
    }

    func stop() {
        generation += 1
        guard let stream else { return }
        self.stream = nil
        meter.reset()
        Self.tearDown(stream)
    }

    /// Reopens on the configured device, for when the selection changes.
    func restart(sampleRate: Int, deviceName: String?) {
        stop()
        start(sampleRate: sampleRate, deviceName: deviceName)
    }

    private func adopt(_ stream: any AudioStream, from generation: Int) {
        // The pane was closed while this was opening. Nothing is watching the
        // meter now, so the microphone must not be left on.
        guard generation == self.generation else {
            Self.tearDown(stream)
            return
        }
        self.stream = stream
    }

    private func noteFailure(from generation: Int) {
        guard generation == self.generation else { return }
        didFail = true
    }

    private static func tearDown(_ stream: any AudioStream) {
        Task.detached(priority: .utility) {
            stream.abort()
            stream.close()
        }
    }
}
