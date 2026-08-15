import Foundation

/// The injectable dependencies the recording state machine is built against
/// (plan §3). Every one of these exists because `tests/test_recovery.py` drives
/// the real state machine with a fake in its place -- wedged streams, refusing
/// clipboards, transcribers that raise or finish out of order. Designing for
/// that first is what makes the port verifiable without a microphone.

// MARK: - Audio

/// A live input stream.
///
/// Every method is **synchronous and may block indefinitely**. That is not an
/// oversight: it mirrors the real CoreAudio behaviour this whole design exists
/// to survive, and it is what lets `Bounded.run` park a dedicated thread on a
/// call that will never return. Making these `async` would hide the hazard and
/// starve the cooperative pool instead.
public protocol AudioStream: AnyObject, Sendable {
    func start() throws
    func abort()
    func stop()
    func close()
}

/// Opens input streams. Opening blocks too -- when a previous teardown is still
/// parked inside the audio subsystem, the *open* blocks behind it, silently,
/// because nothing is logged until the stream is live (daemon.py:149-153).
///
/// **The returned stream is not started.** The caller owns `start()`, because
/// only the caller knows whether the dictation is still wanted by the time the
/// open returns -- a bounded open can be abandoned while it is in flight, and
/// a stream started by the opener would already be capturing into nothing.
/// Starting twice is not harmless: `AVAudioEngine` raises on a second
/// `installTapOnBus` for the same bus.
public protocol AudioStreamOpening: Sendable {
    func open() throws -> any AudioStream
}

/// Opening the input stream blocked long enough that we gave up.
///
/// Distinct from the errors the audio layer itself raises: those usually mean a
/// stale device cache that a reset-and-retry clears, whereas this one means the
/// subsystem is wedged (daemon.py:437).
public struct AudioStreamUnavailable: Error, Equatable {
    public let detail: String
    public init(detail: String = "input stream did not open in time") {
        self.detail = detail
    }
}

// MARK: - Time

/// Monotonic time and sleeping, injectable so tests can drive timeouts and
/// idle thresholds without actually waiting.
///
/// Monotonic rather than wall-clock: every use here measures an *elapsed*
/// interval (how long a teardown has run, how long since the last dictation),
/// and a wall-clock jump from an NTP correction or a daylight-saving change
/// would corrupt those.
public protocol MonotonicClock: Sendable {
    /// Seconds from an arbitrary fixed origin. Only differences are meaningful.
    var now: Double { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: MonotonicClock {
    public init() {}
    public var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

// MARK: - Pasteboard

/// The macOS pasteboard, narrowed to what the insertion path needs.
public protocol Pasteboard: Sendable {
    func read() -> String
    /// Returns whether the write is confirmed to have taken effect. The real
    /// pasteboard can refuse a write without raising (daemon.py:277), and a
    /// caller that trusts an unchecked write will paste the user's previous
    /// clipboard instead of the dictation.
    @discardableResult
    func write(_ text: String) -> Bool
    /// Increments on every change by anyone. Used to tell "still ours" from
    /// "the user copied something during the restore window".
    var changeCount: Int { get }
}

// MARK: - Transcription

public protocol Transcriber: Sendable {
    func transcribe(_ audio: [Float]) async throws -> String
}
