import Foundation
import Testing
@testable import OpenWhisperCore

@Suite("Stats and recent transcripts")
struct StatsStoreTests {

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Recording counts words and recordings")
    func recordingCounts() async throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(StatsStore(directory: dir))

        await store.record("one two three")
        await store.record("four five")

        #expect(await store.stats.totalWords == 5)
        #expect(await store.stats.totalRecordings == 2)
    }

    @Test("Empty or whitespace-only text is not recorded")
    func emptyTextIgnored() async throws {
        // A dictation that cleaned down to nothing must not inflate the
        // recording count or push a blank entry into Recent Transcripts.
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(StatsStore(directory: dir))

        await store.record("")
        await store.record("   \n  ")

        #expect(await store.stats.totalRecordings == 0)
        #expect(await store.recent.isEmpty)
    }

    @Test("Recent transcripts are newest first and capped at ten")
    func recentIsCappedNewestFirst() async throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(StatsStore(directory: dir))

        for i in 1...15 {
            await store.record("dictation \(i)")
        }

        let recent = await store.recent
        #expect(recent.count == StatsStore.recentLimit)
        #expect(recent.first?.text == "dictation 15", "newest must be first")
        #expect(recent.last?.text == "dictation 6")
    }

    @Test("State survives a reload")
    func statePersists() async throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try #require(StatsStore(directory: dir))
        await first.record("hello world")

        let second = try #require(StatsStore(directory: dir))
        await second.load()

        #expect(await second.stats.totalWords == 2)
        #expect(await second.recent.first?.text == "hello world")
    }

    @Test("Files use the Python's names and schema")
    func filesMatchPythonSchema() async throws {
        // The Phase 6 import is a file copy, so a rename here would silently
        // break it — and both apps may write these names.
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(StatsStore(directory: dir))
        await store.record("one two")

        let statsData = try Data(contentsOf: dir.appendingPathComponent("api-usage.json"))
        let stats = try #require(
            try JSONSerialization.jsonObject(with: statsData) as? [String: Any]
        )
        #expect(stats["total_words"] as? Int == 2)
        #expect(stats["total_recordings"] as? Int == 1)

        let recentData = try Data(contentsOf: dir.appendingPathComponent("recent-transcripts.json"))
        let recent = try #require(
            try JSONSerialization.jsonObject(with: recentData) as? [[String: Any]]
        )
        #expect(recent.first?["text"] as? String == "one two")
        #expect(recent.first?["ts"] is String)
    }

    @Test("Timestamps use the Python's naive local format")
    func timestampFormat() {
        // time.strftime('%Y-%m-%dT%H:%M:%S') — no timezone suffix, no
        // fractional seconds. Both apps may write the same file.
        let stamp = RecentTranscript.timestamp(
            for: Date(timeIntervalSince1970: 1_760_000_000)
        )
        #expect(stamp.count == 19, "got \(stamp)")
        #expect(stamp.contains("T"))
        #expect(!stamp.hasSuffix("Z"))
        #expect(!stamp.contains("+"))
    }

    @Test("Clearing empties the list but keeps lifetime counters")
    func clearKeepsCounters() async throws {
        // "Clear" is about the visible list, not about erasing history the
        // stats line reports.
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(StatsStore(directory: dir))

        await store.record("one two three")
        await store.clearRecent()

        #expect(await store.recent.isEmpty)
        #expect(await store.stats.totalWords == 3)
        #expect(await store.stats.totalRecordings == 1)
    }

    @Test("A corrupt stats file falls back to zeros rather than failing")
    func corruptFileTolerated() async throws {
        // The counters are decoration; refusing to run over a bad JSON file
        // would cost the user their dictation tool for nothing.
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent("api-usage.json"))

        let store = try #require(StatsStore(directory: dir))
        await store.load()

        #expect(await store.stats.totalWords == 0)
    }
}
