import Foundation
import Testing

@testable import VerbaliseCore

/// The compile queue's guarantees.
///
/// These are the invariants the lifecycle bugs traced back to: compiles
/// running concurrently, the same model compiled twice, a failure wedging the
/// queue. Each is pinned here with the compile work faked, since the real one
/// is minutes of WhisperKit.
@Suite("Model preparer")
struct ModelPreparerTests {

    /// A latch tests can hold a fake compile on until they choose to let go.
    actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    /// What the fake compile saw: every entry, and how many ran at once.
    actor Recorder {
        private(set) var started: [TranscriptionModel] = []
        private(set) var running = 0
        private(set) var maxConcurrent = 0

        func enter(_ model: TranscriptionModel) {
            started.append(model)
            running += 1
            maxConcurrent = max(maxConcurrent, running)
        }

        func exit() {
            running -= 1
        }
    }

    @Test("Concurrent callers for one model share one compile")
    func concurrentCallersShareOneCompile() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let preparer = ModelPreparer(
            isPrepared: { _ in false },
            compile: { model in
                await recorder.enter(model)
                await gate.wait()
                await recorder.exit()
            }
        )

        async let first: Void = preparer.ensurePrepared(.fast)
        async let second: Void = preparer.ensurePrepared(.fast)

        // Give both callers time to reach the queue before releasing it.
        try? await Task.sleep(for: .milliseconds(50))
        await gate.open()
        try await first
        try await second

        #expect(await recorder.started == [.fast])
    }

    @Test("Compiles for different models never overlap")
    func compilesAreSerialised() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let preparer = ModelPreparer(
            isPrepared: { _ in false },
            compile: { model in
                await recorder.enter(model)
                await gate.wait()
                await recorder.exit()
            }
        )

        async let first: Void = preparer.ensurePrepared(.fast)
        async let second: Void = preparer.ensurePrepared(.balanced)

        // While the first compile is held on the gate, the second must be
        // queued behind it, not running beside it.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.started == [.fast])

        await gate.open()
        try await first
        try await second

        #expect(await recorder.started == [.fast, .balanced])
        #expect(await recorder.maxConcurrent == 1)
    }

    @Test("An already-prepared model is not compiled")
    func preparedModelIsSkipped() async throws {
        let recorder = Recorder()
        let preparer = ModelPreparer(
            isPrepared: { _ in true },
            compile: { model in
                await recorder.enter(model)
                await recorder.exit()
            }
        )

        try await preparer.ensurePrepared(.fast)

        #expect(await recorder.started.isEmpty)
        #expect(await preparer.inFlight.isEmpty)
    }

    @Test("A model stamped while it queued is skipped at its turn")
    func queuedModelRechecksTheStamp() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let stamped = Stamped()
        let preparer = ModelPreparer(
            isPrepared: { stamped.contains($0) },
            compile: { model in
                await recorder.enter(model)
                await gate.wait()
                await recorder.exit()
            }
        )

        async let first: Void = preparer.ensurePrepared(.fast)
        try? await Task.sleep(for: .milliseconds(50))

        // While fast holds the queue, balanced becomes prepared by other
        // means (a re-download that re-stamped). Its queued compile must
        // notice and stand down rather than spend minutes proving nothing.
        async let second: Void = preparer.ensurePrepared(.balanced)
        try? await Task.sleep(for: .milliseconds(50))
        stamped.insert(.balanced)

        await gate.open()
        try await first
        try await second

        #expect(await recorder.started == [.fast])
        #expect(await preparer.inFlight.isEmpty)
    }

    @Test("A failed compile throws, clears state, and can be retried")
    func failurePropagatesAndRetries() async throws {
        let attempts = Counter()
        let preparer = ModelPreparer(
            isPrepared: { _ in false },
            compile: { _ in
                if attempts.increment() == 1 { throw Failure() }
            }
        )

        await #expect(throws: Failure.self) {
            try await preparer.ensurePrepared(.fast)
        }
        #expect(await preparer.inFlight.isEmpty)

        // The failure is not sticky: the next ask compiles again.
        try await preparer.ensurePrepared(.fast)
        #expect(attempts.value == 2)
    }

    @Test("A failure ahead in the queue does not wedge what is behind it")
    func failureDoesNotBlockTheQueue() async throws {
        let recorder = Recorder()
        let preparer = ModelPreparer(
            isPrepared: { _ in false },
            compile: { model in
                await recorder.enter(model)
                await recorder.exit()
                if model == .fast { throw Failure() }
            }
        )

        let first = Task { try await preparer.ensurePrepared(.fast) }
        let second = Task { try await preparer.ensurePrepared(.balanced) }

        await #expect(throws: Failure.self) { try await first.value }
        try await second.value

        #expect(await recorder.started == [.fast, .balanced])
    }

    @Test("inFlight reports queued and running models, then empties")
    func inFlightTracksTheQueue() async throws {
        let gate = Gate()
        let snapshots = Snapshots()
        let preparer = ModelPreparer(
            isPrepared: { _ in false },
            compile: { _ in await gate.wait() },
            onChange: { snapshots.append($0) }
        )

        async let first: Void = preparer.ensurePrepared(.fast)
        async let second: Void = preparer.ensurePrepared(.balanced)
        try? await Task.sleep(for: .milliseconds(50))

        // Both the running compile and the queued one count as in flight:
        // each is committed work someone is waiting on.
        #expect(await preparer.inFlight == [.fast, .balanced])

        await gate.open()
        try await first
        try await second

        #expect(await preparer.inFlight.isEmpty)
        #expect(snapshots.last == [])
    }

    // MARK: - Helpers

    struct Failure: Error {}

    /// A thread-safe set standing in for the preparation stamp.
    final class Stamped: @unchecked Sendable {
        private let lock = NSLock()
        private var models: Set<TranscriptionModel> = []

        func contains(_ model: TranscriptionModel) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return models.contains(model)
        }

        func insert(_ model: TranscriptionModel) {
            lock.lock(); models.insert(model); lock.unlock()
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        @discardableResult
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count
        }
    }

    final class Snapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [Set<TranscriptionModel>] = []

        func append(_ snapshot: Set<TranscriptionModel>) {
            lock.lock(); all.append(snapshot); lock.unlock()
        }

        var last: Set<TranscriptionModel>? {
            lock.lock(); defer { lock.unlock() }
            return all.last
        }
    }
}
