import Foundation
import Testing

@testable import OpenWhisperCore

/// The waveform's response curve.
///
/// The thing being protected is that the bars move usefully at *any* speaking
/// volume. A fixed gain looked right at one volume and wrong at every other,
/// which is what this replaces.
@Suite("Level scaler")
struct LevelScalerTests {

    /// Roughly where normal speech sits, and where a raised voice does.
    private static let conversational = 0.03
    private static let loud = 0.25

    @Test("Silence stays at the floor rather than going to nothing")
    func silenceRests() {
        var scaler = LevelScaler()
        #expect(scaler.scale(0) == LevelScaler.minimumHeight)
        // A flat line of zero-height bars reads as a hung app.
        #expect(LevelScaler.minimumHeight > 0)
    }

    @Test("Normal speech uses a useful part of the range")
    func conversationalSpeechIsVisible() {
        var scaler = LevelScaler()
        var height = 0.0
        // A second of steady speech at 20Hz.
        for _ in 0..<20 { height = scaler.scale(Self.conversational) }

        // The old fixed gain of 8 put this at 0.24 -- a barely-moving line.
        #expect(height > 0.4, "conversational speech should fill the bars, got \(height)")
    }

    @Test("Raising your voice still visibly does something")
    func loudIsLouder() {
        var quiet = LevelScaler()
        var shout = LevelScaler()
        var quietHeight = 0.0
        var shoutHeight = 0.0
        for _ in 0..<20 {
            quietHeight = quiet.scale(Self.conversational)
            shoutHeight = shout.scale(Self.loud)
        }
        // Pure normalisation would make these identical, which is the failure
        // mode this deliberately avoids.
        #expect(shoutHeight > quietHeight)
    }

    @Test("The scale comes back down after a loud moment")
    func referenceReleases() {
        var scaler = LevelScaler()
        _ = scaler.scale(Self.loud)
        let raisedReference = scaler.currentReference

        // Two seconds of quiet at 20Hz.
        for _ in 0..<40 { _ = scaler.scale(Self.conversational) }

        #expect(scaler.currentReference < raisedReference,
                "one loud word must not flatten everything after it")
    }

    @Test("The reference never falls below its floor")
    func referenceHasAFloor() {
        var scaler = LevelScaler()
        // A long silence. Without a floor the next tiny sound would divide by
        // near-zero and the bars would thrash on room noise.
        for _ in 0..<400 { _ = scaler.scale(0) }
        #expect(scaler.currentReference == LevelScaler.referenceFloor)
    }

    @Test("Output never leaves 0...1")
    func outputIsBounded() {
        var scaler = LevelScaler()
        for raw in [0, 0.001, 0.05, 0.5, 1, 4, -1] as [Double] {
            let height = scaler.scale(raw)
            #expect(height >= LevelScaler.minimumHeight)
            #expect(height <= 1)
        }
    }

    @Test("A sudden loud sound does not overshoot")
    func attackIsInstant() {
        var scaler = LevelScaler()
        for _ in 0..<20 { _ = scaler.scale(Self.conversational) }
        // Rising instantly is what stops a shout clipping at full height for
        // several frames before the scale catches up.
        #expect(scaler.scale(Self.loud) <= 1)
    }

    @Test("Reset forgets a loud session")
    func resetClearsTheReference() {
        var scaler = LevelScaler()
        _ = scaler.scale(Self.loud)
        scaler.reset()
        #expect(scaler.currentReference == LevelScaler.referenceFloor)
    }
}
