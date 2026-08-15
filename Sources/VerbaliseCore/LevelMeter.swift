import Foundation

/// Bridges audio levels from the realtime thread to the pill's animation.
///
/// The two run at unrelated rates and must stay that way. Audio buffers arrive
/// whenever CoreAudio delivers them — a rate set by hardware buffer size, and
/// made uneven again by the sample-rate converter, which emits a variable
/// number of frames per input buffer. Driving the waveform directly off that
/// makes it scroll in fits and starts.
///
/// So the meter decouples them: the audio thread reports as often as it likes,
/// and the animation samples on its own steady timer.
///
/// `read` returns the **peak since the last read**, not the latest value. That
/// matters at both ends of the rate mismatch: when buffers arrive faster than
/// the animation samples, no transient is missed; when they arrive slower, the
/// decay below keeps the bars falling smoothly instead of holding a flat line.
public final class LevelMeter: @unchecked Sendable {

    private let lock = NSLock()
    private var peak: Float = 0
    private var lastRead: Float = 0

    /// How much of the previous reading survives a read with no new audio.
    /// Makes the bars fall away rather than snapping to zero the moment the
    /// speaker pauses.
    private let decay: Float = 0.6

    public init() {}

    /// Called from the audio thread, once per delivered buffer.
    public func report(_ level: Float) {
        lock.lock()
        peak = max(peak, level)
        lock.unlock()
    }

    /// Called from the animation timer at a fixed rate.
    public func read() -> Float {
        lock.lock()
        defer { lock.unlock() }

        if peak > 0 {
            lastRead = peak
            peak = 0
        } else {
            lastRead *= decay
            if lastRead < 0.0005 { lastRead = 0 }
        }
        return lastRead
    }

    public func reset() {
        lock.lock()
        peak = 0
        lastRead = 0
        lock.unlock()
    }
}
