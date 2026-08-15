import Foundation
import Testing

@testable import VerbaliseCore

/// The download owner's guarantees: join don't duplicate, cancel cleans up
/// without racing a restart, and stale progress can never repaint a row.
@Suite("Model downloader")
struct ModelDownloaderTests {

    @Test("Concurrent callers for one model share one download")
    func joinersShareOneDownload() async throws {
        let script = DownloadScript()
        let downloader = ModelDownloader(
            isDownloaded: { _ in false },
            download: { model, report in try await script.run(model, report) },
            removePartial: { script.notePartialRemoved($0) }
        )

        let first = Task { try await downloader.ensureDownloaded(.accurate) }
        let second = Task { try await downloader.ensureDownloaded(.accurate) }

        try? await Task.sleep(for: .milliseconds(50))
        script.finishCurrent()
        try await first.value
        try await second.value

        #expect(script.invocations == 1)
    }

    @Test("A model already on disk is not downloaded again")
    func alreadyOnDiskSkips() async throws {
        let script = DownloadScript()
        let downloader = ModelDownloader(
            isDownloaded: { _ in true },
            download: { model, report in try await script.run(model, report) },
            removePartial: { script.notePartialRemoved($0) }
        )

        try await downloader.ensureDownloaded(.accurate)

        #expect(script.invocations == 0)
        #expect(await downloader.inFlight.isEmpty)
    }

    @Test("Progress lands in inFlight; zero reads as size-unknown")
    func progressFlowsThrough() async throws {
        let script = DownloadScript()
        let downloader = ModelDownloader(
            isDownloaded: { _ in false },
            download: { model, report in try await script.run(model, report) },
            removePartial: { script.notePartialRemoved($0) }
        )

        let task = Task { try await downloader.ensureDownloaded(.accurate) }
        try? await Task.sleep(for: .milliseconds(50))

        script.report(0)
        try? await Task.sleep(for: .milliseconds(50))
        // A zero fraction means the total is still unknown, which the row
        // draws as an indeterminate bar rather than one pinned at 0%.
        #expect(await downloader.inFlight[.accurate] == Double??.some(nil))

        script.report(0.4)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await downloader.inFlight[.accurate] == 0.4)

        script.finishCurrent()
        try await task.value
        #expect(await downloader.inFlight.isEmpty)
    }

    @Test("Cancel interrupts every waiter and discards the partial download")
    func cancelThrowsAndCleansUp() async throws {
        let script = DownloadScript()
        let downloader = ModelDownloader(
            isDownloaded: { _ in false },
            download: { model, report in try await script.run(model, report) },
            removePartial: { script.notePartialRemoved($0) }
        )

        let waiter = Task { try await downloader.ensureDownloaded(.accurate) }
        try? await Task.sleep(for: .milliseconds(50))

        await downloader.cancel(.accurate)
        // The row clears the moment the user asks, not when the transfer
        // gets around to unwinding.
        #expect(await downloader.inFlight.isEmpty)

        script.finishCurrent()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(script.partialsRemoved == [.accurate])
    }

    @Test("A restart while the cancelled transfer unwinds keeps its files")
    func restartOutrunsTheCleanup() async throws {
        let script = DownloadScript()
        let downloader = ModelDownloader(
            isDownloaded: { _ in false },
            download: { model, report in try await script.run(model, report) },
            removePartial: { script.notePartialRemoved($0) }
        )

        let first = Task { try await downloader.ensureDownloaded(.accurate) }
        try? await Task.sleep(for: .milliseconds(50))
        await downloader.cancel(.accurate)

        // The user clicks Download again before the cancelled transfer has
        // unwound. The pending cleanup must notice and leave the fresh
        // download's files alone.
        let second = Task { try await downloader.ensureDownloaded(.accurate) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(script.invocations == 2)

        script.finish(invocation: 1)
        await #expect(throws: CancellationError.self) { try await first.value }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(script.partialsRemoved.isEmpty)

        script.finish(invocation: 2)
        try await second.value
        #expect(script.partialsRemoved.isEmpty)
    }

    @Test("A transfer that outruns its cancel still counts as cancelled")
    func completedTransferStillHonoursCancel() async throws {
        // Seen live: a small model on a fast connection finishes before the
        // cancellation reaches the transfer layer. The files are discarded by
        // the cancel's cleanup, so the waiter must hear "cancelled", not
        // "downloaded" — the designed outcome (revert the staged switch)
        // hangs off that distinction.
        let script = DownloadScript(honourCancellation: false)
        let downloader = ModelDownloader(
            isDownloaded: { _ in false },
            download: { model, report in try await script.run(model, report) },
            removePartial: { script.notePartialRemoved($0) }
        )

        let waiter = Task { try await downloader.ensureDownloaded(.fast) }
        try? await Task.sleep(for: .milliseconds(50))

        await downloader.cancel(.fast)
        script.finishCurrent()   // The transfer completes as if never cancelled.

        await #expect(throws: CancellationError.self) { try await waiter.value }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(script.partialsRemoved == [.fast])
    }

    @Test("Progress from a cancelled transfer cannot repaint the row")
    func staleProgressIsIgnored() async throws {
        let script = DownloadScript()
        let downloader = ModelDownloader(
            isDownloaded: { _ in false },
            download: { model, report in try await script.run(model, report) },
            removePartial: { script.notePartialRemoved($0) }
        )

        let waiter = Task { try await downloader.ensureDownloaded(.accurate) }
        try? await Task.sleep(for: .milliseconds(50))

        await downloader.cancel(.accurate)

        // The dying transfer reports one last time on its way out.
        script.report(0.9)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await downloader.inFlight.isEmpty)

        script.finishCurrent()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    @Test("A failed download throws, clears state, and can be retried")
    func failurePropagatesAndRetries() async throws {
        let script = DownloadScript(failFirst: true)
        let downloader = ModelDownloader(
            isDownloaded: { _ in false },
            download: { model, report in try await script.run(model, report) },
            removePartial: { script.notePartialRemoved($0) }
        )

        let first = Task { try await downloader.ensureDownloaded(.accurate) }
        try? await Task.sleep(for: .milliseconds(50))
        script.finishCurrent()
        await #expect(throws: Failure.self) { try await first.value }
        #expect(await downloader.inFlight.isEmpty)

        let second = Task { try await downloader.ensureDownloaded(.accurate) }
        try? await Task.sleep(for: .milliseconds(50))
        script.finishCurrent()
        try await second.value
        #expect(script.invocations == 2)
    }

    // MARK: - Helpers

    struct Failure: Error {}

    /// A scriptable stand-in for the transfer layer: each invocation blocks
    /// until the test releases it, honours task cancellation the way
    /// URLSession does, and hands its progress callback out for stale-report
    /// scenarios.
    final class DownloadScript: @unchecked Sendable {
        private let lock = NSLock()
        private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<Int> = []
        private var count = 0
        private var lastReport: (@Sendable (Double) -> Void)?
        private var removed: [TranscriptionModel] = []
        private let failFirst: Bool
        private let honourCancellation: Bool

        init(failFirst: Bool = false, honourCancellation: Bool = true) {
            self.failFirst = failFirst
            self.honourCancellation = honourCancellation
        }

        var invocations: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        var partialsRemoved: [TranscriptionModel] {
            lock.lock(); defer { lock.unlock() }
            return removed
        }

        func run(
            _ model: TranscriptionModel,
            _ report: @escaping @Sendable (Double) -> Void
        ) async throws {
            let invocation: Int = {
                lock.lock(); defer { lock.unlock() }
                count += 1
                lastReport = report
                return count
            }()

            await withCheckedContinuation { continuation in
                lock.lock()
                if released.contains(invocation) {
                    lock.unlock()
                    continuation.resume()
                } else {
                    releases[invocation] = continuation
                    lock.unlock()
                }
            }
            // A well-behaved transfer throws when its task is cancelled — but
            // a fast one can also complete before the cancel reaches it,
            // which is what honourCancellation: false simulates.
            if honourCancellation { try Task.checkCancellation() }
            if failFirst, invocation == 1 { throw Failure() }
        }

        func report(_ fraction: Double) {
            lock.lock()
            let report = lastReport
            lock.unlock()
            report?(fraction)
        }

        func finishCurrent() {
            lock.lock()
            let pending = releases
            releases.removeAll()
            for key in pending.keys { released.insert(key) }
            lock.unlock()
            for continuation in pending.values { continuation.resume() }
        }

        func finish(invocation: Int) {
            lock.lock()
            let continuation = releases.removeValue(forKey: invocation)
            released.insert(invocation)
            lock.unlock()
            continuation?.resume()
        }

        func notePartialRemoved(_ model: TranscriptionModel) {
            lock.lock(); removed.append(model); lock.unlock()
        }
    }
}
