import Testing
@testable import OpenWhisperCore

@Suite("Level meter")
struct LevelMeterTests {

    @Test("A read returns the peak since the last read, not the latest value")
    func readReturnsPeakNotLatest() {
        // Audio buffers arrive faster than the animation samples, so a meter
        // that kept only the most recent value would drop every transient
        // between frames and flatten the waveform.
        let meter = LevelMeter()
        meter.report(0.2)
        meter.report(0.9)
        meter.report(0.3)

        #expect(meter.read() == 0.9)
    }

    @Test("Each read consumes the peak")
    func readConsumesPeak() {
        let meter = LevelMeter()
        meter.report(0.8)

        #expect(meter.read() == 0.8)
        // Nothing new reported, so the next read must not repeat the peak —
        // that is what produced flat steps in the waveform.
        #expect(meter.read() < 0.8)
    }

    @Test("With no new audio the level decays rather than snapping to zero")
    func decaysSmoothly() {
        // A speaker pausing mid-sentence should see the bars fall away, not
        // collapse in a single frame.
        let meter = LevelMeter()
        meter.report(1.0)
        _ = meter.read()

        let first = meter.read()
        let second = meter.read()

        #expect(first > 0)
        #expect(second > 0)
        #expect(second < first, "each quiet read should be lower")
    }

    @Test("Decay reaches exactly zero rather than an ever-smaller float")
    func decayReachesZero() {
        let meter = LevelMeter()
        meter.report(1.0)
        for _ in 0..<200 { _ = meter.read() }
        #expect(meter.read() == 0)
    }

    @Test("Reset clears both the peak and the decaying tail")
    func resetClears() {
        // Called when a new dictation starts; the previous one's tail must not
        // bleed into the first frame of the next.
        let meter = LevelMeter()
        meter.report(0.9)
        meter.reset()
        #expect(meter.read() == 0)
    }

    @Test("A fresh meter reads zero")
    func freshMeterIsZero() {
        #expect(LevelMeter().read() == 0)
    }
}
