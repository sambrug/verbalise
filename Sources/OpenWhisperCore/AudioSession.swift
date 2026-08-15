import Foundation

/// Owns the input stream's lifecycle and survives a wedged audio subsystem.
///
/// This is the component `tests/test_recovery.py` was written for. The failure
/// it defends against: macOS stops running our IO proc, so the stream's
/// blocking `stop`/`close` never returns, and a state machine that waits for it
/// is stuck forever with the pill showing "recording" and a dead trigger key.
///
/// Every call into the audio subsystem is therefore time-bounded, and the
/// subsystem is treated as *suspect* after any overrun. One overrun is not
/// grounds for drastic action -- a slow device looks the same -- but a second
/// failure on top of a suspect subsystem cannot be recovered in-process, and
/// escalates (daemon.py:1250).
public actor AudioSession {

    public struct Timeouts: Sendable {
        /// Long enough for a cold Bluetooth device, short enough that a wedged
        /// open does not read as a hang.
        public var open: Duration = .seconds(5)
        public var teardown: Duration = .seconds(2)

        public init(open: Duration = .seconds(5), teardown: Duration = .seconds(2)) {
            self.open = open
            self.teardown = teardown
        }
    }

    private let opener: any AudioStreamOpening
    private let onEscalate: @Sendable () -> Void

    public var timeouts: Timeouts

    /// Set when a call into the audio subsystem overran. Sticky until a
    /// healthy open clears it.
    public private(set) var isSubsystemSuspect = false

    /// Only meaningful for tests and diagnostics: how many streams we opened
    /// but had to abandon.
    public private(set) var orphanCount = 0

    /// - Parameter onEscalate: invoked when the subsystem is wedged beyond
    ///   in-process recovery. In the single-process design this drives a
    ///   persistent menu alert pointing the user at Restart, replacing the
    ///   Python supervisor's exit-and-relaunch (plan §3).
    public init(
        opener: any AudioStreamOpening,
        timeouts: Timeouts = .init(),
        onEscalate: @escaping @Sendable () -> Void = {}
    ) {
        self.opener = opener
        self.timeouts = timeouts
        self.onEscalate = onEscalate
    }

    public func setTimeouts(_ timeouts: Timeouts) {
        self.timeouts = timeouts
    }

    /// For tests reproducing "an earlier teardown was already abandoned".
    public func markSubsystemSuspect() {
        isSubsystemSuspect = true
    }

    // MARK: - Opening

    private enum OpenOutcome: Sendable {
        case opened(any AudioStream)
        case failed(String)
        /// Opened, but only after we had given up -- already closed.
        case orphaned
    }

    /// Opens a stream, or throws `AudioStreamUnavailable` if it overruns.
    ///
    /// A stream that arrives after we gave up is closed rather than returned:
    /// left running it would feed the audio callback behind the next
    /// dictation's back.
    public func open() async throws -> any AudioStream {
        let wasSuspect = isSubsystemSuspect
        let opener = self.opener

        let outcome = await Bounded.run(timeout: timeouts.open) { isAbandoned -> OpenOutcome in
            do {
                let stream = try opener.open()
                if isAbandoned() {
                    stream.close()
                    return .orphaned
                }
                return .opened(stream)
            } catch {
                return .failed("\(error)")
            }
        }

        switch outcome {
        case .opened(let stream):
            // A healthy open is the evidence that the subsystem recovered.
            // Nothing else clears the flag, so without this a single slow
            // device would leave the app one strike from escalating forever.
            if isSubsystemSuspect {
                log("audio: subsystem recovered, clearing suspect flag")
                isSubsystemSuspect = false
            }
            return stream

        case .failed(let detail):
            log("audio: open failed — \(detail)")
            throw AudioStreamUnavailable(detail: detail)

        case .orphaned:
            // Cannot happen: `.orphaned` is only produced after `isAbandoned`
            // is true, by which point Bounded has already returned nil below.
            orphanCount += 1
            throw AudioStreamUnavailable(detail: "stream arrived after giving up")

        case nil:
            orphanCount += 1
            isSubsystemSuspect = true
            if wasSuspect {
                // Second failure on an already-suspect subsystem. In-process
                // recovery has been tried and did not work.
                log("audio: open timed out with subsystem already suspect — escalating")
                onEscalate()
            } else {
                // First strike is reported, not escalated: it might simply be
                // a slow device rather than a wedged subsystem.
                log("audio: open timed out (first strike)")
            }
            throw AudioStreamUnavailable()
        }
    }

    // MARK: - Teardown

    /// Stops and closes `stream`, giving up if it overruns.
    ///
    /// Returns whether teardown completed. A false return means a thread is now
    /// parked inside the audio subsystem indefinitely -- accepted deliberately,
    /// because the alternative is the whole app parked with it.
    @discardableResult
    public func teardown(_ stream: any AudioStream) async -> Bool {
        let completed = await Bounded.run(timeout: timeouts.teardown) {
            // abort() before close(): abort asks the device to stop *without*
            // waiting to drain, which is the one call with a chance of
            // returning when the IO proc is already gone.
            stream.abort()
            stream.close()
            return true
        }

        if completed == nil {
            isSubsystemSuspect = true
            log("audio: teardown overran \(timeouts.teardown.seconds)s — abandoning the stream")
            return false
        }
        return true
    }
}
