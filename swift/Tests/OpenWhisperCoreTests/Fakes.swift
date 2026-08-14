import Foundation
@testable import OpenWhisperCore

/// Test doubles behind the plan's §3 seams, mirroring the fakes in
/// tests/test_recovery.py so the Swift scenarios stay recognisably the same.

/// A stream whose stop/abort/close never return -- the real failure mode.
///
/// CoreAudio's blocking stop waits for the audio callback to acknowledge; when
/// the OS has stopped running our IO proc, that never happens.
final class WedgedStream: AudioStream, @unchecked Sendable {
    private let lock = NSLock()
    private var _abortEntered = false

    var abortEntered: Bool {
        lock.lock(); defer { lock.unlock() }
        return _abortEntered
    }

    func start() throws {}

    func abort() {
        lock.lock(); _abortEntered = true; lock.unlock()
        // Parks forever, exactly like the real thing. The test process can
        // strand this thread; that is the behaviour under test.
        Thread.sleep(forTimeInterval: 3600)
    }

    func stop() { Thread.sleep(forTimeInterval: 3600) }
    func close() { Thread.sleep(forTimeInterval: 3600) }
}

final class HealthyStream: AudioStream, @unchecked Sendable {
    /// Raised on a second `start()`, mirroring AVAudioEngine.
    ///
    /// The real engine throws an Objective-C exception from
    /// `installTapOnBus` when a tap is already installed on that bus, which
    /// terminates the process rather than surfacing as a Swift error. A fake
    /// that quietly tolerated a double start would let exactly that crash
    /// through the suite — it did, once.
    struct StartedTwice: Error {}

    private let lock = NSLock()
    private var _closed = false
    private var _startCount = 0

    var closed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _closed
    }
    var started: Bool { startCount > 0 }
    var startCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _startCount
    }

    func start() throws {
        lock.lock()
        _startCount += 1
        let count = _startCount
        lock.unlock()
        if count > 1 { throw StartedTwice() }
    }

    func abort() {}
    func stop() {}
    func close() { lock.lock(); _closed = true; lock.unlock() }
}

/// Hands back a fresh healthy stream and records every open.
final class HealthyOpener: AudioStreamOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [HealthyStream] = []

    var opened: [HealthyStream] {
        lock.lock(); defer { lock.unlock() }
        return _opened
    }
    var openCount: Int { opened.count }

    func open() throws -> any AudioStream {
        let stream = HealthyStream()
        lock.lock(); _opened.append(stream); lock.unlock()
        return stream
    }
}

/// An open that never returns: what a wedged subsystem does to the *next*
/// dictation. The audio layer serialises internally, so an open blocks behind
/// a teardown thread still parked inside it -- silently, because nothing is
/// logged until the stream is live.
struct BlockedOpener: AudioStreamOpening {
    func open() throws -> any AudioStream {
        Thread.sleep(forTimeInterval: 3600)
        return HealthyStream()
    }
}

/// An open that eventually succeeds, but only after the caller has given up.
final class LateOpener: AudioStreamOpening, @unchecked Sendable {
    let stream = HealthyStream()
    private let gate = DispatchSemaphore(value: 0)

    /// Lets the pending open finally return.
    func release() { gate.signal() }

    func open() throws -> any AudioStream {
        _ = gate.wait(timeout: .now() + 5)
        return stream
    }
}

struct ThrowingOpener: AudioStreamOpening {
    struct Failure: Error {}
    func open() throws -> any AudioStream { throw Failure() }
}

// MARK: - Clock

/// A clock whose time only moves when a test moves it, so timeout and idle
/// thresholds can be exercised without real waiting.
final class TestClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Double

    init(now: Double = 1_000) { _now = now }

    var now: Double {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    func advance(by seconds: Double) {
        lock.lock(); _now += seconds; lock.unlock()
    }

    func sleep(for duration: Duration) async throws {
        advance(by: duration.seconds)
        await Task.yield()
    }
}

// MARK: - Pasteboard

/// Stands in for NSPasteboard, with a refusal mode.
final class FakeClipboard: Pasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String
    private var _changeCount = 0
    private var _writes: [String] = []

    /// When true, every write silently fails -- the real pasteboard server
    /// does this when it is busy (daemon.py:277).
    var refuseWrites: Bool

    /// Invoked after each successful read, so a test can simulate another app
    /// taking the pasteboard between our write and the paste keystroke.
    var onRead: (@Sendable () -> Void)?

    init(initial: String = "PREVIOUS CLIPBOARD", refuseWrites: Bool = false) {
        _value = initial
        self.refuseWrites = refuseWrites
    }

    var writes: [String] {
        lock.lock(); defer { lock.unlock() }
        return _writes
    }

    var value: String {
        get {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        set { set(newValue) }
    }

    /// A change made by someone other than us.
    func set(_ text: String) {
        lock.lock()
        _value = text
        _changeCount += 1
        lock.unlock()
    }

    func read() -> String {
        lock.lock()
        let current = _value
        lock.unlock()
        onRead?()
        return current
    }

    @discardableResult
    func write(_ text: String) -> Bool {
        if refuseWrites { return false }
        lock.lock()
        _value = text
        _changeCount += 1
        _writes.append(text)
        lock.unlock()
        return true
    }

    var changeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _changeCount
    }
}

// MARK: - Keyboard

/// Captures what would have been typed or pasted instead of sending it to
/// whatever app has focus.
final class FakeKeyboard: KeyboardPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _typed: [String] = []
    private var _pasteCount = 0

    var typed: [String] {
        lock.lock(); defer { lock.unlock() }
        return _typed
    }
    var pasteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _pasteCount
    }

    func typeUnicode(_ text: String) {
        lock.lock(); _typed.append(text); lock.unlock()
    }

    func postPasteShortcut() {
        lock.lock(); _pasteCount += 1; lock.unlock()
    }
}

// MARK: - Transcription

/// Returns a fixed string for every chunk.
struct FixedTranscriber: Transcriber {
    let text: String
    init(_ text: String = "hello world") { self.text = text }
    func transcribe(_ audio: [Float]) async throws -> String { text }
}

struct FailingTranscriber: Transcriber {
    struct Failure: Error {}
    func transcribe(_ audio: [Float]) async throws -> String { throw Failure() }
}

/// First call is slow, so completion order differs from feed order. Proves the
/// streamer restores order by index rather than by whichever finished first.
final class OutOfOrderTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func transcribe(_ audio: [Float]) async throws -> String {
        // withLock rather than lock()/unlock(): the latter is unavailable in an
        // async context because a lock must never be held across a suspension,
        // and this function suspends just below.
        let call = lock.withLock {
            callCount += 1
            return callCount
        }

        if call == 1 {
            try await Task.sleep(for: .milliseconds(200))
            return "one"
        }
        return "two"
    }
}
