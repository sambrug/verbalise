import Foundation

/// Runs a blocking operation with a wall-clock ceiling, abandoning it if it
/// overruns.
///
/// This exists for one specific failure (daemon.py:1268): when CoreAudio stops
/// running our IO proc, a blocking `stop`/`close` on the input stream waits
/// forever for a callback acknowledgement that will never come. The state
/// machine cannot be allowed to wait with it, or the pill sticks on "recording"
/// and the trigger key goes dead until the app is restarted.
///
/// The overrunning work is **abandoned, not cancelled**. There is no way to
/// interrupt a thread parked inside CoreAudio, so the thread stays parked --
/// possibly forever -- while the caller moves on. That leaks a thread, which is
/// the correct trade: one stranded thread costs far less than a wedged app, and
/// the process is expected to be restarted eventually anyway.
public enum Bounded {

    /// Runs `operation` on a background thread. Returns its result, or nil if
    /// `timeout` elapsed first.
    public static func run<T: Sendable>(
        timeout: Duration,
        _ operation: @escaping @Sendable () -> T
    ) async -> T? {
        await run(timeout: timeout) { _ in operation() }
    }

    /// As above, but `operation` is handed a predicate telling it whether the
    /// caller has already given up on it.
    ///
    /// This is what makes orphan cleanup possible. An `open` that overruns is
    /// abandoned, but it may still succeed minutes later and hand back a live
    /// stream that nobody owns -- which then feeds the audio callback behind
    /// the next dictation's back (daemon.py:218-232). Checking `isAbandoned`
    /// before returning lets the operation close its own orphan.
    ///
    /// The answer is authoritative, not a race: the flag flips under the same
    /// lock that resumes the continuation, so exactly one of "finished in time"
    /// and "abandoned" is ever true, and the operation observes the same one
    /// the caller did.
    public static func run<T: Sendable>(
        timeout: Duration,
        _ operation: @escaping @Sendable (_ isAbandoned: @Sendable () -> Bool) -> T
    ) async -> T? {
        let gate = ResumeOnce<T>()

        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.attach(continuation)

            // Deliberately not a Task: `operation` is blocking, and parking a
            // cooperative-pool thread inside CoreAudio would starve the pool.
            // A dedicated Thread can be stranded without consequence.
            let thread = Thread {
                let value = operation({ gate.didTimeOut })
                gate.finish(value)
            }
            thread.stackSize = 512 * 1024
            thread.start()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds) {
                gate.timeout()
            }
        }
    }

    /// Delivers exactly one of "finished" or "timed out" to a continuation,
    /// whichever happens first. Resuming a continuation twice traps, and both
    /// callers race by construction, so the one-shot guarantee is enforced here
    /// rather than assumed.
    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var timedOut = false

        /// True once the caller has given up. Set under the same lock that
        /// resumes the continuation, so an operation that reads it after
        /// finishing sees the same outcome the caller acted on.
        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }

        func attach(_ continuation: CheckedContinuation<T?, Never>) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        func finish(_ value: T) { resume(value, timedOut: false) }
        func timeout() { resume(nil, timedOut: true) }

        private func resume(_ value: T?, timedOut: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            // Only the winner records the outcome; a late `finish` after a
            // timeout must not clear the flag the operation is about to read.
            if pending != nil, timedOut { self.timedOut = true }
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

extension Duration {
    /// Seconds as a Double, for the Dispatch and Foundation APIs that want one.
    public var seconds: Double {
        let (whole, attoseconds) = components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}
