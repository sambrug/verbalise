import Foundation

/// One entry in the Recent Transcripts list.
///
/// Field names and the timestamp format match the Python exactly
/// (daemon.py:639) so the Phase 6 import is a file copy rather than a
/// translation: `{"text": ..., "ts": "2026-08-14T13:43:27"}`.
public struct RecentTranscript: Codable, Equatable, Sendable {
    public let text: String
    public let ts: String

    public init(text: String, ts: String) {
        self.text = text
        self.ts = ts
    }

    /// Local time, no timezone suffix — the Python used
    /// `time.strftime('%Y-%m-%dT%H:%M:%S')`, which is naive local time.
    /// Matching it matters because both apps may write the same file.
    public static func timestamp(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// Lifetime counters and the recent-transcripts ring (daemon.py:599-648).
///
/// Two files with the Python's names and shapes, in the app container:
/// `api-usage.json` and `recent-transcripts.json`.
public actor StatsStore {

    public static let recentLimit = 10

    private let statsURL: URL
    private let recentURL: URL

    public private(set) var stats = UsageStats()
    public private(set) var recent: [RecentTranscript] = []

    public init?(directory: URL? = nil) {
        let base: URL
        if let directory {
            base = directory
        } else {
            guard let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ) else { return nil }
            base = support
        }
        statsURL = base.appendingPathComponent("api-usage.json")
        recentURL = base.appendingPathComponent("recent-transcripts.json")
    }

    /// Reads both files, tolerating absence and corruption.
    ///
    /// A stats file that fails to parse must not stop the app or lose the
    /// user's dictation — the counters are decoration, and starting from zero
    /// is a better outcome than refusing to run.
    public func load() {
        if let data = try? Data(contentsOf: statsURL),
           let decoded = try? JSONDecoder().decode(UsageStats.self, from: data) {
            stats = decoded
        }
        if let data = try? Data(contentsOf: recentURL),
           let decoded = try? JSONDecoder().decode([RecentTranscript].self, from: data) {
            recent = Array(decoded.prefix(Self.recentLimit))
        }
    }

    /// Counts a dictation and prepends it to the recent list.
    public func record(_ text: String, at date: Date = Date()) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words > 0 else { return }

        stats.totalWords += words
        stats.totalRecordings += 1

        recent.insert(RecentTranscript(text: text, ts: RecentTranscript.timestamp(for: date)), at: 0)
        if recent.count > Self.recentLimit {
            recent.removeLast(recent.count - Self.recentLimit)
        }
        persist()
    }

    public func clearRecent() {
        recent = []
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        try? encoder.encode(stats).write(to: statsURL, options: .atomic)
        try? encoder.encode(recent).write(to: recentURL, options: .atomic)
    }
}
