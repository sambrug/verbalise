import Foundation
import Testing
@testable import OpenWhisperCore

/// Differential tests against the Python implementation (plan §6).
///
/// The expected values in `Fixtures/text-pipeline.json` are not hand-written --
/// they are whatever `daemon.py` actually produced, recorded by
/// `Scripts/generate-fixtures.py`. That matters because the value of this port
/// is behavioural equivalence, including the parts of the regexes nobody would
/// think to assert. Hand-written expectations would encode what I *believe* the
/// Python does; these encode what it *does*.
///
/// Regenerate after any change to the Python pipeline:
///     .venv/bin/python3 swift/Scripts/generate-fixtures.py
@Suite("Differential tests against the Python pipeline")
struct FixtureTests {

    // MARK: - Fixture loading

    struct Fixtures: Decodable {
        struct CleanCase: Decodable {
            let input: String
            let expected: String
        }
        struct BoolCase: Decodable {
            let input: String
            let expected: Bool
        }
        struct JoinCase: Decodable {
            let input: [String]
            let expected: String
        }
        struct PhoneticCase: Decodable {
            let input: String
            let corrections: [[String]]
            let expected: String
        }
        struct StatsCase: Decodable {
            let input: UsageStats
            let expected: String
        }
        struct OptionalStatsCase: Decodable {
            let input: UsageStats
            let expected: String?
        }

        let cleanHallucinations: [CleanCase]
        let looksLikeRepetitionLoop: [BoolCase]
        let joinStreamingChunks: [JoinCase]
        let applyPhoneticCorrections: [PhoneticCase]
        let formatStats: [StatsCase]
        let formatTimeSaved: [OptionalStatsCase]
    }

    static let fixtures: Fixtures = {
        guard let url = Bundle.module.url(
            forResource: "text-pipeline",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            fatalError("text-pipeline.json missing — run Scripts/generate-fixtures.py")
        }
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }()

    // MARK: - Cases

    @Test("Fixture file is populated")
    func fixturesLoaded() {
        // Guards against the suite silently passing on an empty file.
        #expect(Self.fixtures.cleanHallucinations.count >= 30)
        #expect(Self.fixtures.joinStreamingChunks.count >= 10)
        #expect(Self.fixtures.applyPhoneticCorrections.count >= 8)
    }

    @Test("clean_hallucinations matches Python")
    func cleanHallucinationsMatchesPython() {
        for (index, testCase) in Self.fixtures.cleanHallucinations.enumerated() {
            let actual = TextPipeline.cleanHallucinations(testCase.input)
            #expect(
                actual == testCase.expected,
                """
                case \(index): \(testCase.input.debugDescription)
                  python: \(testCase.expected.debugDescription)
                  swift:  \(actual.debugDescription)
                """
            )
        }
    }

    @Test("looks_like_repetition_loop matches Python")
    func repetitionLoopMatchesPython() {
        for (index, testCase) in Self.fixtures.looksLikeRepetitionLoop.enumerated() {
            let actual = TextPipeline.looksLikeRepetitionLoop(testCase.input)
            #expect(
                actual == testCase.expected,
                "case \(index): \(testCase.input.debugDescription) — python \(testCase.expected), swift \(actual)"
            )
        }
    }

    @Test("join_streaming_chunks matches Python")
    func joinStreamingChunksMatchesPython() {
        for (index, testCase) in Self.fixtures.joinStreamingChunks.enumerated() {
            let actual = TextPipeline.joinStreamingChunks(testCase.input)
            #expect(
                actual == testCase.expected,
                """
                case \(index): \(testCase.input)
                  python: \(testCase.expected.debugDescription)
                  swift:  \(actual.debugDescription)
                """
            )
        }
    }

    @Test("_apply_phonetic_corrections matches Python")
    func phoneticCorrectionsMatchPython() {
        for (index, testCase) in Self.fixtures.applyPhoneticCorrections.enumerated() {
            let corrections = testCase.corrections.map {
                (misheard: $0[0], correct: $0[1])
            }
            let actual = TextPipeline.applyPhoneticCorrections(
                testCase.input, corrections: corrections
            )
            #expect(
                actual == testCase.expected,
                """
                case \(index): \(testCase.input.debugDescription) with \(testCase.corrections)
                  python: \(testCase.expected.debugDescription)
                  swift:  \(actual.debugDescription)
                """
            )
        }
    }

    @Test("format_stats matches Python")
    func formatStatsMatchesPython() {
        for testCase in Self.fixtures.formatStats {
            let actual = StatsFormatter.formatStats(testCase.input)
            #expect(
                actual == testCase.expected,
                "\(testCase.input) — python \(testCase.expected.debugDescription), swift \(actual.debugDescription)"
            )
        }
    }

    @Test("format_time_saved matches Python")
    func formatTimeSavedMatchesPython() {
        for testCase in Self.fixtures.formatTimeSaved {
            let actual = StatsFormatter.formatTimeSaved(testCase.input)
            #expect(
                actual == testCase.expected,
                "\(testCase.input) — python \(String(describing: testCase.expected)), swift \(String(describing: actual))"
            )
        }
    }
}

@Suite("Rounding parity with Python")
struct PythonRoundingTests {

    @Test("Half values round to even, as Python does")
    func halfRoundsToEven() {
        // Swift's .rounded() would give 3, 4, 5, 6 here. Python gives 2, 4, 4, 6.
        #expect(StatsFormatter.pythonRound(2.5) == 2)
        #expect(StatsFormatter.pythonRound(3.5) == 4)
        #expect(StatsFormatter.pythonRound(4.5) == 4)
        #expect(StatsFormatter.pythonRound(5.5) == 6)
    }

    @Test("Non-half values round normally")
    func normalRounding() {
        #expect(StatsFormatter.pythonRound(2.4) == 2)
        #expect(StatsFormatter.pythonRound(2.6) == 3)
        #expect(StatsFormatter.pythonRound(59.98) == 60)
    }
}
