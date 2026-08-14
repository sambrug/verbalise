import Foundation
import Testing
@testable import OpenWhisperCore

/// Scenario groups 4-8 from tests/test_recovery.py.
@Suite("Dictation state machine")
struct DictationControllerTests {

    // MARK: - Harness

    final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [DictationEvent] = []

        var events: [DictationEvent] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }
        var pillCommands: [PillCommand] {
            events.compactMap { if case .pill(let c) = $0 { return c } else { return nil } }
        }
        var lastTexts: [String] {
            events.compactMap { if case .lastText(let t) = $0 { return t } else { return nil } }
        }
        var warnings: [String] {
            events.compactMap { if case .warning(let w) = $0 { return w } else { return nil } }
        }

        func record(_ event: DictationEvent) {
            lock.lock(); _events.append(event); lock.unlock()
        }
    }

    /// Runs a hook mid-transcription, so a test can abandon the dictation while
    /// the model is still "working".
    struct HookedTranscriber: Transcriber {
        let text: String
        let hook: @Sendable () async -> Void

        func transcribe(_ audio: [Float]) async throws -> String {
            await hook()
            return text
        }
    }

    static let sampleRate = 16_000
    /// Five seconds of audio: comfortably over min_duration.
    static let audio = [Float](repeating: 0.1, count: sampleRate * 5)

    static let fastTimeouts = AudioSession.Timeouts(
        open: .milliseconds(300),
        teardown: .milliseconds(300)
    )

    struct Harness {
        let controller: DictationController
        let events: EventRecorder
        let keyboard: FakeKeyboard
        let clipboard: FakeClipboard
        let opener: HealthyOpener
        let session: AudioSession
        let clock: TestClock
    }

    static func makeHarness(
        transcriber: any Transcriber = FixedTranscriber(),
        opener: HealthyOpener = HealthyOpener()
    ) -> Harness {
        let events = EventRecorder()
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        let clock = TestClock()
        let session = AudioSession(opener: opener, timeouts: fastTimeouts)

        var settings = Settings()
        settings.advanced.clipboardRestoreDelay = 0
        settings.releaseDelay = 0

        let controller = DictationController(
            session: session,
            transcriber: transcriber,
            inserter: TextInserter(keyboard: keyboard, pasteboard: clipboard, clock: clock),
            settings: settings,
            clock: clock,
            emit: { events.record($0) }
        )
        return Harness(
            controller: controller, events: events, keyboard: keyboard,
            clipboard: clipboard, opener: opener, session: session, clock: clock
        )
    }

    // MARK: - 8. The normal path, end to end

    @Test("normal path: transcribed, typed, stream closed, pill hidden")
    func normalPath() async {
        let h = Self.makeHarness()
        let stream = HealthyStream()

        await h.controller._prepareForTest(stream: stream, audio: Self.audio, secondsAgo: 5)
        await h.controller.stopAndTranscribe()

        #expect(h.keyboard.typed == ["hello world"])
        #expect(stream.closed)
        #expect(await h.controller.state == .idle)
        #expect(h.events.lastTexts == ["hello world"])
        // recording -> transcribing -> hidden
        #expect(h.pillSequenceIsNormal)
        #expect(await h.session.isSubsystemSuspect == false, "no false wedge flag")
    }

    @Test("a dictation under min_duration is ignored")
    func underMinDurationIgnored() async {
        let h = Self.makeHarness()
        // 0.2s, under the 0.5s default.
        let shortAudio = [Float](repeating: 0.1, count: Self.sampleRate / 5)

        await h.controller._prepareForTest(stream: HealthyStream(), audio: shortAudio)
        await h.controller.stopAndTranscribe()

        #expect(h.keyboard.typed.isEmpty)
        #expect(await h.controller.state == .idle)
        #expect(h.events.pillCommands.last == .hide)
    }

    // MARK: - 1 (controller level). A wedged device still recovers

    @Test("wedged device: captured audio still transcribed and pill hidden")
    func wedgedDeviceStillTranscribes() async {
        // The audio already captured is good even though the device will not
        // shut down. Losing the dictation on top of the wedge would be gratuitous.
        let h = Self.makeHarness()

        await h.controller._prepareForTest(stream: WedgedStream(), audio: Self.audio)

        let start = Date()
        await h.controller.stopAndTranscribe()
        let elapsed = Date().timeIntervalSince(start)

        #expect(h.keyboard.typed == ["hello world"])
        #expect(await h.controller.state == .idle)
        #expect(h.events.pillCommands.last == .hide)
        #expect(await h.session.isSubsystemSuspect, "the wedge must be recorded")
        #expect(elapsed < 2.0, "bounded, took \(elapsed)s")
    }

    @Test("startRecording starts the stream exactly once")
    func streamStartedExactlyOnce() async {
        // The opener returns an unstarted stream and the controller starts it.
        // When both did, AVAudioEngine raised from installTapOnBus on the
        // second call and killed the process the moment the trigger key was
        // pressed — a crash no unit test caught, because the fake tolerated it.
        let opener = HealthyOpener()
        let h = Self.makeHarness(opener: opener)

        await h.controller.startRecording()

        #expect(opener.openCount == 1)
        let stream = try? #require(opener.opened.first)
        #expect(stream?.startCount == 1, "started \(stream?.startCount ?? -1) times")
        #expect(await h.controller.state == .recording)
    }

    @Test("a reopened stream is also started exactly once")
    func reopenedStreamStartedOnce() async {
        // captureHealthCheck opens a replacement; same ownership rule applies.
        let opener = HealthyOpener()
        let h = Self.makeHarness(opener: opener)
        await h.controller.setCaptureHealthDelay(.seconds(3))

        await h.controller._prepareForTest(stream: HealthyStream(), audio: [])
        h.clock.advance(by: 5)
        await h.controller.captureHealthCheck()

        #expect(opener.openCount == 1)
        #expect(opener.opened.first?.startCount == 1)
    }

    // MARK: - 4. Escape

    @Test("escape on a stalled stop: state reset, nothing typed")
    func escapeOnStalledStop() async {
        // Hold the transcription open so the controller genuinely sits in
        // .transcribing, then let the stop go overdue and hit Escape.
        let gate = AsyncGate()
        let h = Self.makeHarness(
            transcriber: HookedTranscriber(text: "hello world") { await gate.wait() }
        )
        await h.controller._prepareForTest(stream: HealthyStream(), audio: Self.audio)
        await h.controller.setStallEscapeThreshold(.seconds(3))

        let stopTask = Task { await h.controller.stopAndTranscribe() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await h.controller.state == .transcribing)

        // Well past the stall threshold now.
        h.clock.advance(by: 10)
        await h.controller.handleEscape()

        #expect(await h.controller.state == .idle)
        #expect(h.events.pillCommands.last == .hide)

        // The abandoned transcription still completes. It must not type.
        gate.open()
        await stopTask.value
        #expect(h.keyboard.typed.isEmpty, "typed \(h.keyboard.typed)")
    }

    @Test("escape during a healthy transcription: left alone")
    func escapeDuringHealthyTranscription() async {
        // Escape must not throw away a dictation that is merely taking a moment.
        let gate = AsyncGate()
        let h = Self.makeHarness(
            transcriber: HookedTranscriber(text: "hello world") {
                await gate.wait()
            }
        )
        await h.controller._prepareForTest(stream: HealthyStream(), audio: Self.audio)
        await h.controller.setStallEscapeThreshold(.seconds(3))

        let stopTask = Task { await h.controller.stopAndTranscribe() }
        try? await Task.sleep(for: .milliseconds(50))

        // Only 0.5s into the stop: not stalled.
        h.clock.advance(by: 0.5)
        await h.controller.handleEscape()
        #expect(await h.controller.state == .transcribing, "still transcribing")

        gate.open()
        await stopTask.value

        // The dictation survived and was typed.
        #expect(h.keyboard.typed == ["hello world"])
    }

    @Test("escape while recording cancels and types nothing")
    func escapeWhileRecordingCancels() async {
        let h = Self.makeHarness()
        let stream = HealthyStream()
        await h.controller._prepareForTest(stream: stream, audio: Self.audio)

        await h.controller.handleEscape()

        #expect(await h.controller.state == .idle)
        #expect(h.keyboard.typed.isEmpty, "nothing may be typed for a cancelled recording")
        #expect(stream.closed)
        #expect(h.events.pillCommands.last == .hide)
    }

    // MARK: - 5. A device that starts but never delivers audio

    @Test("dead mic: stream reopened, recording continues")
    func deadMicIsReopened() async {
        let opener = HealthyOpener()
        let h = Self.makeHarness(opener: opener)
        await h.controller.setCaptureHealthDelay(.seconds(3))

        await h.controller._prepareForTest(stream: HealthyStream(), audio: [])
        // No audio has arrived for longer than the health delay.
        h.clock.advance(by: 5)

        await h.controller.captureHealthCheck()

        #expect(opener.openCount == 1, "the input must be reopened")
        #expect(await h.controller.state == .recording, "recording continues")
    }

    @Test("healthy mic: no reopen")
    func healthyMicNotReopened() async {
        let opener = HealthyOpener()
        let h = Self.makeHarness(opener: opener)
        await h.controller.setCaptureHealthDelay(.seconds(3))

        await h.controller._prepareForTest(stream: HealthyStream(), audio: [])
        // Audio is arriving normally.
        await h.controller.appendAudio([Float](repeating: 0.1, count: 1600))

        await h.controller.captureHealthCheck()

        #expect(opener.openCount == 0)
        #expect(await h.controller.state == .recording)
    }

    @Test("health check does nothing when not recording")
    func healthCheckIdleNoop() async {
        let opener = HealthyOpener()
        let h = Self.makeHarness(opener: opener)
        h.clock.advance(by: 100)

        await h.controller.captureHealthCheck()
        #expect(opener.openCount == 0)
    }

    // MARK: - 6. A leaked max-duration timer

    @Test("leaked timer: ignored when nothing is recording")
    func leakedTimerIgnoredWhenIdle() async {
        let h = Self.makeHarness()
        // A timer from generation 0 firing while the controller sits idle.
        await h.controller._autoStopForTest(gen: 0)

        #expect(await h.controller.state == .idle)
        #expect(h.keyboard.typed.isEmpty)
    }

    @Test("leaked timer: never cuts a later dictation short")
    func leakedTimerDoesNotCutLaterDictation() async {
        // The failure this prevents: a timer from a finished dictation fires
        // during the *next* one and stops it mid-sentence.
        let h = Self.makeHarness()
        await h.controller._prepareForTest(stream: HealthyStream(), audio: Self.audio)
        let staleGeneration = await h.controller._generationForTest - 1

        await h.controller._autoStopForTest(gen: staleGeneration)

        #expect(await h.controller.state == .recording, "the live dictation must survive")
        #expect(h.keyboard.typed.isEmpty)
    }

    // MARK: - 7. An abandoned dictation must never type later

    @Test("abandoned dictation: text not typed")
    func abandonedDictationDoesNotType() async {
        // Escape or a force reset landing while the transcription is in flight.
        // Typing now would insert text into whatever the user moved on to.
        let controllerBox = Box<DictationController>()
        let hooked = HookedTranscriber(text: "hello world") {
            await controllerBox.value?.forceReset()
        }

        let h = Self.makeHarness(transcriber: hooked)
        controllerBox.value = h.controller

        await h.controller._prepareForTest(stream: HealthyStream(), audio: Self.audio)
        await h.controller.stopAndTranscribe()

        #expect(h.keyboard.typed.isEmpty, "typed \(h.keyboard.typed)")
        #expect(h.events.lastTexts.isEmpty)
        #expect(await h.controller.state == .idle)
    }
}

// MARK: - Small helpers

/// One-shot gate a test can hold a transcription open with.
final class AsyncGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false

    func open() {
        lock.lock()
        let alreadyOpen = opened
        opened = true
        lock.unlock()
        if !alreadyOpen { semaphore.signal() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { [semaphore] in
                _ = semaphore.wait(timeout: .now() + 5)
                continuation.resume()
            }
        }
    }
}

/// Lets a fake reach back to the controller that owns it.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?

    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

extension DictationControllerTests.Harness {
    /// recording shown, switched to transcribing, then hidden.
    var pillSequenceIsNormal: Bool {
        events.pillCommands == [.show("recording"), .setState("transcribing"), .hide]
    }
}
