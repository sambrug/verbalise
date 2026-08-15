import Foundation

/// Turns microphone levels into bar heights that respond at any speaking volume.
///
/// A fixed gain cannot do this. Speech RMS spans more than an order of
/// magnitude between a quiet room and a raised voice, so a multiplier tuned to
/// look right when shouting leaves normal speech as a barely-moving line — the
/// waveform then reads as broken, and the jump to the processing pulse, which
/// has no such problem, looks abrupt by comparison.
///
/// So the scale adapts. A reference level tracks recent peaks, rises instantly
/// and falls slowly, and levels are measured against it: quiet speech fills the
/// bars because the reference has come down to meet it.
///
/// It is not pure normalisation, which would flatten everything to the same
/// height and lose the difference between talking and shouting entirely. The
/// result is mostly relative with some absolute mixed back in, so raising your
/// voice still visibly does something.
public struct LevelScaler {

    /// The quietest reference worth measuring against.
    ///
    /// Without a floor, silence divides a tiny number by a tiny number and the
    /// bars thrash on room noise.
    public static let referenceFloor: Double = 0.05

    /// How much of the previous reference survives each reading.
    ///
    /// At the pill's 20Hz sampling this halves in about two seconds — long
    /// enough that a single loud word does not permanently flatten everything
    /// after it, short enough to follow someone lowering their voice.
    static let release: Double = 0.985

    /// The fixed multiplier, kept for the absolute component. Matches what the
    /// pill used before this existed.
    static let absoluteGain: Double = 8

    /// How much of the result is relative rather than absolute.
    static let adaptiveShare: Double = 0.65

    /// Bars never go fully flat: a line of nothing looks like a hung app.
    public static let minimumHeight: Double = 0.02

    private var reference = LevelScaler.referenceFloor

    public init() {}

    /// The current reference, for tests and diagnostics.
    public var currentReference: Double { reference }

    public mutating func scale(_ raw: Double) -> Double {
        let level = max(raw, 0)

        // Instant attack, slow release. Rising immediately means a sudden loud
        // sound never clips; falling slowly means the bars do not pump between
        // syllables.
        reference = max(level, max(reference * Self.release, Self.referenceFloor))

        let adaptive = min(level / reference, 1)
        let absolute = min(level * Self.absoluteGain, 1)
        let blended = Self.adaptiveShare * adaptive
            + (1 - Self.adaptiveShare) * absolute

        return min(max(blended, Self.minimumHeight), 1)
    }

    public mutating func reset() {
        reference = Self.referenceFloor
    }
}
