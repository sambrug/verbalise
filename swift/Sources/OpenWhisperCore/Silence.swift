import Foundation

/// RMS-based silence analysis over 16 kHz mono float samples.
/// Ported from daemon.py:328 (`trim_silence`) and :397 (`silence_gap_index`).
public enum Silence {

    /// Trims leading and trailing silence using RMS hysteresis with padding
    /// (daemon.py:328). Returns the trimmed audio and how many samples were
    /// removed, so the caller can log the saving.
    ///
    /// Hysteresis -- a higher threshold to enter speech than to leave it --
    /// stops a speaker who trails off quietly from having their last word
    /// clipped, which a single threshold would do.
    ///
    /// Both safety guards return the audio *untouched* rather than a trimmed
    /// version. Handing Whisper a clip that is too short, or trimming so little
    /// it cannot matter, is worse than not trimming at all.
    public static func trim(
        _ audio: [Float],
        sampleRate: Int
    ) -> (trimmed: [Float], savedSamples: Int) {
        guard !audio.isEmpty else { return (audio, 0) }

        let frameLength = max(Int(Double(sampleRate) * 0.020), 1)  // 20ms
        let hop = max(Int(Double(sampleRate) * 0.010), 1)          // 10ms
        guard audio.count >= frameLength * 2 else { return (audio, 0) }

        var frameStarts: [Int] = []
        var start = 0
        while start <= audio.count - frameLength {
            frameStarts.append(start)
            start += hop
        }
        guard !frameStarts.isEmpty else { return (audio, 0) }

        let rmsValues = frameStarts.map { rms(audio, from: $0, length: frameLength) }

        let enterThreshold: Float = 0.006
        let exitThreshold: Float = 0.004
        let minQuietFrames = max(Int(0.120 / 0.010), 1)  // 120ms

        var inSpeech = false
        var quietFrames = 0
        var speechStart: Int?
        var speechEnd: Int?

        for (i, value) in rmsValues.enumerated() {
            if !inSpeech {
                if value >= enterThreshold {
                    inSpeech = true
                    quietFrames = 0
                    if speechStart == nil { speechStart = i }
                    speechEnd = i
                }
            } else {
                if value < exitThreshold {
                    quietFrames += 1
                    if quietFrames >= minQuietFrames {
                        inSpeech = false
                        quietFrames = 0
                    }
                } else {
                    quietFrames = 0
                    speechEnd = i
                }
            }
        }

        if inSpeech { speechEnd = rmsValues.count - 1 }

        guard let firstSpeech = speechStart,
              let lastSpeech = speechEnd,
              lastSpeech >= firstSpeech
        else { return (audio, 0) }

        let startPad = Int(Double(sampleRate) * 0.120)
        let endPad = Int(Double(sampleRate) * 0.200)
        let startSample = max(frameStarts[firstSpeech] - startPad, 0)
        let endSample = min(frameStarts[lastSpeech] + frameLength + endPad, audio.count)

        let trimmed = Array(audio[startSample..<endSample])
        let saved = audio.count - trimmed.count

        // Too short to transcribe reliably.
        if trimmed.count < Int(Double(sampleRate) * 0.350) { return (audio, 0) }
        // Saving is not worth the risk of having clipped something.
        if saved < Int(Double(sampleRate) * 0.080) { return (audio, 0) }

        return (trimmed, saved)
    }

    /// Finds the first sufficiently long low-energy gap at or after
    /// `startIndex` (daemon.py:397). Returns the sample index where the next
    /// streaming chunk should start, or nil when no gap exists yet.
    ///
    /// Tuned conservatively on purpose: a pause for breath or thought
    /// (200-300ms) must *not* trigger a cut, only a clear sentence boundary.
    /// The bar is 400ms of silence after at least 2s of speech.
    public static func gapIndex(
        _ audio: [Float],
        sampleRate: Int,
        startIndex: Int
    ) -> Int? {
        guard audio.count > startIndex, startIndex >= 0 else { return nil }

        let frameLength = max(Int(Double(sampleRate) * 0.020), 1)
        let hop = max(Int(Double(sampleRate) * 0.010), 1)
        let exitThreshold: Float = 0.005
        let minQuietHops = max(Int(0.400 / 0.010), 1)   // 400ms of silence
        let minSpeechHops = max(Int(2.000 / 0.010), 1)  // after 2s of speech

        var sawSpeechHops = 0
        var quietHops = 0
        var quietStart: Int?
        var i = startIndex

        while i + frameLength <= audio.count {
            if rms(audio, from: i, length: frameLength) < exitThreshold {
                if quietStart == nil { quietStart = i }
                quietHops += 1
                if sawSpeechHops >= minSpeechHops, quietHops >= minQuietHops,
                   let quietStart {
                    // Cut *after* the silence: the previous chunk keeps its
                    // trailing silence, which Whisper expects, and the next
                    // chunk starts clean.
                    return quietStart + minQuietHops * hop
                }
            } else {
                sawSpeechHops += 1
                quietStart = nil
                quietHops = 0
            }
            i += hop
        }
        return nil
    }

    static func rms(_ audio: [Float], from start: Int, length: Int) -> Float {
        var sum: Float = 0
        for i in start..<(start + length) {
            sum += audio[i] * audio[i]
        }
        return (sum / Float(length)).squareRoot()
    }
}
