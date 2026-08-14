import Foundation

public enum DictationState: String, Sendable, Equatable {
    case idle, recording, transcribing
}

/// What the pill is told to do. Modelled as commands rather than state so the
/// tests can assert the same sequence the Python suite does.
public enum PillCommand: Sendable, Equatable {
    case show(String)
    case setState(String)
    case hide
}

/// Replaces the Python daemon's stdout JSON event stream (daemon.py:218,
/// consumed at menubar.py:1350). In one process these are just calls.
public enum DictationEvent: Sendable, Equatable {
    case state(DictationState)
    case pill(PillCommand)
    case lastText(String)
    case warning(String)
    case error(String)
    case statsChanged
}

/// The recording state machine (daemon.py class `OpenWhisper`).
///
/// Built against the §3 seams so `tests/test_recovery.py`'s scenarios can drive
/// it with fakes -- wedged streams, dead microphones, transcribers that finish
/// after the dictation has been abandoned. No microphone required.
///
/// The single most important invariant here is the **generation counter**.
/// Every dictation gets a number, and every asynchronous continuation captures
/// the number it started under. Anything that finishes after its generation has
/// moved on -- a transcription completing after Escape, a max-duration timer
/// firing after the user already released the key -- is discarded rather than
/// acted on. Without it, a slow transcription silently types its text into
/// whatever the user was doing several actions later.
public actor DictationController {

    // MARK: - Dependencies

    private let session: AudioSession
    private let transcriber: any Transcriber
    private let inserter: TextInserter
    private let clock: any MonotonicClock
    private let emit: @Sendable (DictationEvent) -> Void

    // MARK: - Tunables

    /// How overdue a stop must be before Escape treats it as stalled. Escape
    /// during a healthy in-flight transcription must leave it alone, or the
    /// user loses a perfectly good dictation by reflex.
    public var stallEscapeThreshold: Duration = .seconds(3)

    /// How long a recording may deliver no audio before the input is reopened.
    public var captureHealthDelay: Duration = .seconds(3)

    // MARK: - State

    public private(set) var state: DictationState = .idle
    public private(set) var settings: Settings

    /// Bumped on every start and every reset. See the type doc.
    private var generation = 0

    private var stream: (any AudioStream)?
    private var buffer: [Float] = []
    private var recordStartedAt: Double = 0
    private var lastAudioAt: Double = 0
    private var stopStartedAt: Double?
    private var maxDurationTask: Task<Void, Never>?

    public init(
        session: AudioSession,
        transcriber: any Transcriber,
        inserter: TextInserter,
        settings: Settings = Settings(),
        clock: any MonotonicClock = SystemClock(),
        emit: @escaping @Sendable (DictationEvent) -> Void = { _ in }
    ) {
        self.session = session
        self.transcriber = transcriber
        self.inserter = inserter
        self.settings = settings
        self.clock = clock
        self.emit = emit
    }

    public func apply(settings: Settings) {
        self.settings = settings
    }

    public func setStallEscapeThreshold(_ value: Duration) { stallEscapeThreshold = value }
    public func setCaptureHealthDelay(_ value: Duration) { captureHealthDelay = value }

    // MARK: - Audio input

    /// Called by the capture layer for each delivered buffer.
    public func appendAudio(_ samples: [Float]) {
        guard state == .recording else { return }
        buffer.append(contentsOf: samples)
        lastAudioAt = clock.now
    }

    /// Test seam: place the controller in the state `startRecording` would have
    /// left it in, without a real device (`as_if_recording` in the Python).
    public func _prepareForTest(
        stream: any AudioStream,
        audio: [Float],
        secondsAgo: Double = 20
    ) {
        generation += 1
        self.stream = stream
        self.buffer = audio
        self.state = .recording
        self.recordStartedAt = clock.now - secondsAgo
        self.lastAudioAt = clock.now
        emit(.pill(.show("recording")))
    }

    // MARK: - Start

    public func startRecording() async {
        guard state == .idle else { return }

        generation += 1
        let gen = generation
        buffer.removeAll()
        recordStartedAt = clock.now
        lastAudioAt = clock.now
        state = .recording
        emit(.state(.recording))
        emit(.pill(.show("recording")))

        do {
            let opened = try await session.open()

            // The open is bounded but not instant, and Escape or a key release
            // can land while it is in flight.
            guard generation == gen, state == .recording else {
                await session.teardown(opened)
                return
            }

            try opened.start()
            stream = opened
            startMaxDurationTimer(gen: gen)
        } catch {
            // Give up cleanly rather than hanging. The symptom this replaces
            // was a trigger key that did nothing at all until the app was
            // restarted, with no indication why.
            log("dictation: could not start — \(error)")
            state = .idle
            stream = nil
            buffer.removeAll()
            cancelMaxDurationTimer()
            emit(.pill(.hide))
            emit(.state(.idle))
            emit(.warning("Microphone unavailable — dictation not started."))
        }
    }

    // MARK: - Stop and transcribe

    public func stopAndTranscribe() async {
        guard state == .recording else { return }

        state = .transcribing
        stopStartedAt = clock.now
        cancelMaxDurationTimer()
        emit(.state(.transcribing))
        emit(.pill(.setState("transcribing")))

        let gen = generation

        // Teardown is bounded: a wedged device must not hold the transcription
        // hostage. The audio we already captured is still good.
        if let live = stream {
            stream = nil
            await session.teardown(live)
        }

        let audio = buffer
        buffer.removeAll()

        let duration = Double(audio.count) / Double(max(settings.sampleRate, 1))
        guard duration >= settings.minDuration else {
            log("dictation: \(String(format: "%.2f", duration))s is under min_duration, ignoring")
            finish(gen: gen)
            return
        }

        do {
            let raw = try await transcriber.transcribe(audio)

            // The dictation may have been abandoned while the model was
            // working. Typing now would insert text into whatever the user
            // moved on to.
            guard generation == gen else {
                log("dictation: abandoned during transcription, not typing")
                return
            }

            let cleaned = TextPipeline.cleanHallucinations(raw)
            let corrected = TextPipeline.applyPhoneticCorrections(
                cleaned, corrections: settings.orderedPhoneticCorrections
            )

            if corrected.isEmpty {
                log("dictation: nothing left after cleaning, typing nothing")
            } else {
                let outcome = await inserter.insert(corrected, settings: settings)
                if let warning = outcome.warning {
                    emit(.warning(warning))
                }
                emit(.lastText(corrected))
                emit(.statsChanged)
            }
        } catch {
            log("dictation: transcription failed — \(error)")
            guard generation == gen else { return }
            emit(.error("Transcription failed."))
        }

        finish(gen: gen)
    }

    private func finish(gen: Int) {
        guard generation == gen else { return }
        state = .idle
        stopStartedAt = nil
        emit(.pill(.hide))
        emit(.state(.idle))
    }

    // MARK: - Escape and force reset

    /// Escape. Cancels a live recording outright; on a stalled stop it is the
    /// manual escape hatch; during a healthy transcription it does nothing.
    public func handleEscape() async {
        switch state {
        case .recording:
            log("dictation: cancelled by Escape")
            await forceReset()

        case .transcribing:
            guard let started = stopStartedAt,
                  clock.now - started >= stallEscapeThreshold.seconds
            else {
                // A transcription that is merely taking a moment. Resetting
                // here would throw away a good dictation on a reflex keypress.
                log("dictation: Escape ignored, transcription is still healthy")
                return
            }
            log("dictation: Escape on a stalled stop, forcing reset")
            await forceReset()

        case .idle:
            return
        }
    }

    /// The universal escape hatch (daemon.py:1458). Everything in flight is
    /// abandoned by moving the generation on.
    public func forceReset() async {
        generation += 1
        let live = stream
        stream = nil
        state = .idle
        stopStartedAt = nil
        buffer.removeAll()
        cancelMaxDurationTimer()
        emit(.pill(.hide))
        emit(.state(.idle))

        if let live {
            await session.teardown(live)
        }
    }

    // MARK: - Watchdogs

    /// Reopens the input when a recording is running but no audio is arriving
    /// (daemon.py:1421) -- a device that starts successfully and then delivers
    /// nothing, which is otherwise indistinguishable from silence.
    public func captureHealthCheck() async {
        guard state == .recording else { return }
        guard clock.now - lastAudioAt >= captureHealthDelay.seconds else { return }

        log("dictation: no audio for \(captureHealthDelay.seconds)s, reopening the input")
        let gen = generation

        if let stale = stream {
            stream = nil
            await session.teardown(stale)
        }

        do {
            let reopened = try await session.open()
            guard generation == gen, state == .recording else {
                await session.teardown(reopened)
                return
            }
            try reopened.start()
            stream = reopened
            // Reset the clock so a slow reopen does not immediately re-trigger.
            lastAudioAt = clock.now
        } catch {
            log("dictation: reopen failed — \(error)")
            emit(.warning("Microphone stopped responding."))
        }
    }

    // MARK: - Max duration

    private func startMaxDurationTimer(gen: Int) {
        cancelMaxDurationTimer()
        let limit = settings.maxDuration
        guard limit > 0 else { return }

        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            await self?.autoStop(gen: gen)
        }
    }

    private func cancelMaxDurationTimer() {
        maxDurationTask?.cancel()
        maxDurationTask = nil
    }

    /// Fires at `max_duration`. Guarded on the generation, because a timer from
    /// a finished dictation must never cut a *later* one short (daemon.py:1528).
    func autoStop(gen: Int) async {
        maxDurationTask = nil

        guard generation == gen, state == .recording else {
            log("dictation: stale max-duration timer ignored")
            return
        }
        log("dictation: hit max_duration, stopping")
        await stopAndTranscribe()
    }

    /// Test seam for the leaked-timer scenario.
    public func _autoStopForTest(gen: Int) async {
        await autoStop(gen: gen)
    }

    public var _generationForTest: Int { generation }
}
