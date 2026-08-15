import Foundation
import Testing
@testable import OpenWhisperCore

/// Scenario groups 1-3 from tests/test_recovery.py, keeping the original
/// scenario names.
@Suite("Audio session recovery")
struct AudioSessionTests {

    /// Short enough to keep the suite fast, long enough that a healthy fake
    /// never races the deadline on a loaded machine.
    static let fast = AudioSession.Timeouts(
        open: .milliseconds(300),
        teardown: .milliseconds(300)
    )

    // MARK: - 1. Release with a wedged device still recovers

    @Test("wedged device: teardown returns inside the ceiling")
    func wedgedTeardownReturns() async {
        let session = AudioSession(opener: HealthyOpener(), timeouts: Self.fast)
        let wedged = WedgedStream()

        let start = Date()
        let completed = await session.teardown(wedged)
        let elapsed = Date().timeIntervalSince(start)

        #expect(completed == false)
        #expect(wedged.abortEntered, "teardown must at least have been attempted")
        // The whole point: bounded, not indefinite.
        #expect(elapsed < Self.fast.teardown.seconds + 1.0, "took \(elapsed)s")
    }

    @Test("wedged device: audio subsystem flagged")
    func wedgedFlagsSubsystem() async {
        let session = AudioSession(opener: HealthyOpener(), timeouts: Self.fast)
        await session.teardown(WedgedStream())
        #expect(await session.isSubsystemSuspect)
    }

    @Test("healthy teardown: no false wedge flag")
    func healthyTeardownNoFlag() async {
        let session = AudioSession(opener: HealthyOpener(), timeouts: Self.fast)
        let stream = HealthyStream()

        #expect(await session.teardown(stream) == true)
        #expect(stream.closed)
        #expect(await session.isSubsystemSuspect == false)
    }

    @Test("after a wedge: the next open still succeeds")
    func nextOpenAfterWedge() async throws {
        // No restart needed -- the next dictation must be able to start.
        let opener = HealthyOpener()
        let session = AudioSession(opener: opener, timeouts: Self.fast)
        await session.teardown(WedgedStream())

        _ = try await session.open()
        #expect(opener.openCount == 1)
    }

    // MARK: - 2. A blocked open gives up instead of hanging

    @Test("blocked open: gave up instead of hanging")
    func blockedOpenGivesUp() async {
        let session = AudioSession(opener: BlockedOpener(), timeouts: Self.fast)

        let start = Date()
        await #expect(throws: AudioStreamUnavailable.self) {
            _ = try await session.open()
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < Self.fast.open.seconds + 1.0, "took \(elapsed)s")
    }

    @Test("blocked open: audio subsystem flagged")
    func blockedOpenFlagsSubsystem() async {
        let session = AudioSession(opener: BlockedOpener(), timeouts: Self.fast)
        _ = try? await session.open()
        #expect(await session.isSubsystemSuspect)
    }

    @Test("blocked open, first strike: no escalation")
    func firstStrikeDoesNotEscalate() async {
        // A first timeout might just be a slow device, so it is reported and
        // not acted on.
        let escalations = Counter()
        let session = AudioSession(
            opener: BlockedOpener(),
            timeouts: Self.fast,
            onEscalate: { escalations.increment() }
        )

        _ = try? await session.open()
        #expect(escalations.value == 0)
    }

    @Test("blocked open, already wedged: escalates")
    func secondStrikeEscalates() async {
        // A timeout on top of an already-suspect subsystem cannot be recovered
        // in-process.
        let escalations = Counter()
        let session = AudioSession(
            opener: BlockedOpener(),
            timeouts: Self.fast,
            onEscalate: { escalations.increment() }
        )
        await session.markSubsystemSuspect()

        _ = try? await session.open()
        #expect(escalations.value == 1)
    }

    @Test("healthy open after a wedge: no escalation, flag cleared")
    func healthyOpenAfterWedgeClearsFlag() async throws {
        // The suspect flag alone is not grounds for drastic action; a healthy
        // open is the evidence the subsystem recovered.
        let escalations = Counter()
        let opener = HealthyOpener()
        let session = AudioSession(
            opener: opener,
            timeouts: Self.fast,
            onEscalate: { escalations.increment() }
        )
        await session.markSubsystemSuspect()

        _ = try await session.open()

        #expect(escalations.value == 0)
        #expect(opener.openCount == 1)
        #expect(await session.isSubsystemSuspect == false)
    }

    @Test("an open that raises is reported without flagging the subsystem")
    func raisingOpenDoesNotFlag() async {
        // A device error is not a wedge: it usually clears on retry, so it must
        // not push the session one strike from escalating.
        let session = AudioSession(opener: ThrowingOpener(), timeouts: Self.fast)

        await #expect(throws: AudioStreamUnavailable.self) {
            _ = try await session.open()
        }
        #expect(await session.isSubsystemSuspect == false)
    }

    // MARK: - 3. A late-arriving stream is closed as an orphan

    @Test("late stream: orphan closed")
    func lateStreamIsClosed() async throws {
        // A stream that finally arrives after we gave up must not be left
        // running, or it feeds the audio callback behind the next dictation's
        // back.
        let opener = LateOpener()
        let session = AudioSession(opener: opener, timeouts: Self.fast)

        await #expect(throws: AudioStreamUnavailable.self) {
            _ = try await session.open()
        }
        #expect(opener.stream.closed == false, "not closed yet — still blocked")

        opener.release()

        // The orphan is closed on the abandoned thread, so poll rather than
        // assume it has already happened.
        try await waitUntil(timeout: .seconds(2)) { opener.stream.closed }
        #expect(opener.stream.closed)
    }
}

// MARK: - Helpers

/// Thread-safe counter for callbacks fired off the test's own task.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock(); _value += 1; lock.unlock()
    }
}

struct TimedOut: Error {}

/// Polls `condition` until true or `timeout` elapses. Used where the work
/// happens on a thread the test does not control.
func waitUntil(
    timeout: Duration,
    poll: Duration = .milliseconds(20),
    _ condition: @Sendable () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout.seconds)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: poll)
    }
    if !condition() { throw TimedOut() }
}
