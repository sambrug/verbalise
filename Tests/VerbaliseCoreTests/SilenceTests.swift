import Testing
@testable import VerbaliseCore

@Suite("Silence trimming and gap detection")
struct SilenceTests {

    static let sampleRate = 16_000

    /// Amplitude comfortably above the 0.006 enter threshold. Alternating sign
    /// gives a real RMS; a DC offset would too, but this is closer to speech.
    static func speech(seconds: Double, amplitude: Float = 0.2) -> [Float] {
        let count = Int(Double(sampleRate) * seconds)
        return (0..<count).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(Double(sampleRate) * seconds))
    }

    // MARK: - trim

    @Test("Empty audio is returned untouched")
    func emptyAudio() {
        let (trimmed, saved) = Silence.trim([], sampleRate: Self.sampleRate)
        #expect(trimmed.isEmpty)
        #expect(saved == 0)
    }

    @Test("Audio shorter than two frames is returned untouched")
    func tooShortToAnalyse() {
        let tiny = [Float](repeating: 0.5, count: 100)
        let (trimmed, saved) = Silence.trim(tiny, sampleRate: Self.sampleRate)
        #expect(trimmed.count == tiny.count)
        #expect(saved == 0)
    }

    @Test("Pure silence is returned untouched rather than trimmed to nothing")
    func allSilence() {
        // No speech was found, so there is no defensible place to cut. Handing
        // back an empty buffer would be worse than transcribing silence.
        let audio = Self.silence(seconds: 3)
        let (trimmed, saved) = Silence.trim(audio, sampleRate: Self.sampleRate)
        #expect(trimmed.count == audio.count)
        #expect(saved == 0)
    }

    @Test("Leading and trailing silence around speech is trimmed")
    func trimsSurroundingSilence() {
        let audio = Self.silence(seconds: 2) + Self.speech(seconds: 2) + Self.silence(seconds: 2)
        let (trimmed, saved) = Silence.trim(audio, sampleRate: Self.sampleRate)

        #expect(saved > 0)
        #expect(trimmed.count < audio.count)
        // The speech itself, plus 120ms and 200ms of padding, must survive.
        #expect(trimmed.count >= Int(Double(Self.sampleRate) * 2.0))
    }

    @Test("Padding is kept around the detected speech")
    func keepsPadding() {
        let leading = 1.0
        let audio = Self.silence(seconds: leading) + Self.speech(seconds: 2) + Self.silence(seconds: 1)
        let (trimmed, _) = Silence.trim(audio, sampleRate: Self.sampleRate)

        // 120ms before and 200ms after means the result is strictly longer than
        // the speech alone -- a clipped first syllable is the failure this
        // padding exists to prevent.
        #expect(trimmed.count > Int(Double(Self.sampleRate) * 2.0))
    }

    @Test("A trim that would save almost nothing is skipped")
    func tinySavingSkipped() {
        // Speech filling nearly the whole buffer: any saving is below the 80ms
        // floor, so the guard returns the original.
        let audio = Self.speech(seconds: 3)
        let (trimmed, saved) = Silence.trim(audio, sampleRate: Self.sampleRate)
        #expect(trimmed.count == audio.count)
        #expect(saved == 0)
    }

    @Test("A trim never returns audio below the 350ms floor")
    func neverReturnsBelowFloor() {
        // The contract the guard exists to enforce: whatever comes back is
        // either the untouched original, or at least 350ms of audio. Never a
        // sliver too short for Whisper to do anything sensible with.
        //
        // In practice the floor rarely binds, because the 120ms + 200ms of
        // padding already exceeds it for any detected speech at all. That is
        // the Python behaviour too (legacy-python/daemon.py:389) and is ported as-is -- the
        // guard is cheap insurance rather than a hot path.
        let floor = Int(Double(Self.sampleRate) * 0.350)

        for speechSeconds in [0.01, 0.05, 0.1, 0.3, 1.0] {
            let audio = Self.silence(seconds: 2)
                + Self.speech(seconds: speechSeconds)
                + Self.silence(seconds: 2)
            let (trimmed, saved) = Silence.trim(audio, sampleRate: Self.sampleRate)

            #expect(
                trimmed.count == audio.count || trimmed.count >= floor,
                "speech=\(speechSeconds)s gave \(trimmed.count) samples (floor \(floor))"
            )
            // Trimming and reporting a saving must agree with each other.
            #expect(saved == audio.count - trimmed.count)
        }
    }

    @Test("Quiet trailing speech is not clipped by the hysteresis")
    func hysteresisKeepsQuietTail() {
        // Between the exit (0.004) and enter (0.006) thresholds: a speaker
        // trailing off. A single-threshold detector would cut this; hysteresis
        // must not, because speech was already in progress.
        let quietTail = [Float](repeating: 0.005, count: Self.sampleRate / 2)
        let audio = Self.silence(seconds: 1) + Self.speech(seconds: 1) + quietTail + Self.silence(seconds: 1)
        let (trimmed, _) = Silence.trim(audio, sampleRate: Self.sampleRate)
        #expect(trimmed.count >= Int(Double(Self.sampleRate) * 1.0))
    }

    // MARK: - gapIndex

    @Test("No gap is reported in continuous speech")
    func noGapInContinuousSpeech() {
        let audio = Self.speech(seconds: 4)
        #expect(Silence.gapIndex(audio, sampleRate: Self.sampleRate, startIndex: 0) == nil)
    }

    @Test("No gap before the 2s speech minimum")
    func noGapBeforeSpeechMinimum() {
        // A long silence, but only 0.5s of speech precedes it. Cutting here
        // would produce a chunk too short to transcribe well.
        let audio = Self.speech(seconds: 0.5) + Self.silence(seconds: 2)
        #expect(Silence.gapIndex(audio, sampleRate: Self.sampleRate, startIndex: 0) == nil)
    }

    @Test("A short pause for breath does not trigger a cut")
    func shortPauseIgnored() {
        // 300ms is under the 400ms bar: thinking, not a sentence boundary.
        let audio = Self.speech(seconds: 3) + Self.silence(seconds: 0.3) + Self.speech(seconds: 1)
        #expect(Silence.gapIndex(audio, sampleRate: Self.sampleRate, startIndex: 0) == nil)
    }

    @Test("A real sentence boundary is found after enough speech")
    func findsRealGap() {
        let audio = Self.speech(seconds: 3) + Self.silence(seconds: 0.6) + Self.speech(seconds: 1)
        let gap = Silence.gapIndex(audio, sampleRate: Self.sampleRate, startIndex: 0)

        #expect(gap != nil)
        if let gap {
            // The cut lands after the silence starts, so the previous chunk
            // keeps the trailing silence Whisper expects.
            #expect(gap > Int(Double(Self.sampleRate) * 3.0))
            #expect(gap < audio.count)
        }
    }

    @Test("startIndex past the end yields no gap")
    func startIndexPastEnd() {
        let audio = Self.speech(seconds: 1)
        #expect(Silence.gapIndex(audio, sampleRate: Self.sampleRate, startIndex: audio.count) == nil)
        #expect(Silence.gapIndex(audio, sampleRate: Self.sampleRate, startIndex: audio.count + 10) == nil)
    }
}
