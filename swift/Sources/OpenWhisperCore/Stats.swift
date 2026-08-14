import Foundation

/// Lifetime usage counters and their menu formatting.
/// Schema matches daemon.py:599-648 so the Python app's stats file can be
/// imported as-is (plan §9 phase 6).
public struct UsageStats: Codable, Equatable, Sendable {
    public var totalWords: Int
    public var totalRecordings: Int

    public init(totalWords: Int = 0, totalRecordings: Int = 0) {
        self.totalWords = totalWords
        self.totalRecordings = totalRecordings
    }

    /// Python's JSON keys, preserved for import compatibility.
    enum CodingKeys: String, CodingKey {
        case totalWords = "total_words"
        case totalRecordings = "total_recordings"
    }
}

public enum StatsFormatter {

    /// Rates behind the "time saved typing" line. Both fixed on purpose: this
    /// is a fun stat rather than a measurement, and deriving it from the word
    /// count alone means it works on stats files recorded long before the line
    /// existed. 40wpm is the conventional average-adult typing speed; 150wpm a
    /// comfortable speaking pace. (menubar.py:668)
    static let typingWPM = 40.0
    static let speakingWPM = 150.0

    /// Groups thousands with a comma regardless of the user's locale, matching
    /// Python's `{:,}`. A locale-aware formatter would render "1.234.567" in
    /// much of Europe and silently break the fixture comparison -- and the
    /// Python app it has to match never localised this either.
    private static let wordFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.usesGroupingSeparator = true
        return f
    }()

    private static func grouped(_ value: Int) -> String {
        wordFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// menubar.py:654
    public static func formatStats(_ usage: UsageStats) -> String {
        if usage.totalWords == 0 && usage.totalRecordings == 0 {
            return "No dictations yet"
        }
        return "\(grouped(usage.totalWords)) words • \(grouped(usage.totalRecordings)) recordings"
    }

    /// menubar.py:672. Returns nil when there is nothing worth showing yet.
    ///
    /// Saved time is how long the words would have taken to type, less how long
    /// they would take to say. It ignores time spent fixing misrecognitions, so
    /// it is indicative rather than a real productivity measure.
    public static func formatTimeSaved(_ usage: UsageStats) -> String? {
        guard usage.totalWords > 0 else { return nil }

        let savedMinutes = Double(usage.totalWords) * (1 / typingWPM - 1 / speakingWPM)
        guard savedMinutes >= 1 else { return nil }

        if savedMinutes < 60 {
            let minutes = Int(pythonRound(savedMinutes))
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes") saved typing"
        }
        let hours = Int(pythonRound(savedMinutes / 60))
        return "\(hours) \(hours == 1 ? "hour" : "hours") saved typing"
    }

    /// Python's `round()` is banker's rounding -- half goes to the nearest
    /// *even* integer, so round(2.5) is 2, not 3. Swift's `.rounded()` rounds
    /// half away from zero and would disagree on every exact .5, which the
    /// word-count thresholds do hit. Match Python explicitly.
    static func pythonRound(_ value: Double) -> Double {
        value.rounded(.toNearestOrEven)
    }
}
