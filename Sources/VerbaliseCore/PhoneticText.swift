import Foundation

/// The `misheard: correct` text format the phonetic-corrections editor uses.
///
/// Lives here rather than in the editor because it is a parser with real edge
/// cases -- a correction whose replacement contains a colon, a line that is not
/// a pair at all -- and because it round-trips: text the user typed becomes a
/// dictionary and must come back looking like what they typed.
public enum PhoneticText {

    /// Dictionary to text, one pair per line, sorted.
    ///
    /// Sorted for the same reason `orderedPhoneticCorrections` is: a Swift
    /// Dictionary has no order to preserve, and hash order would reshuffle the
    /// user's list every time they opened the editor.
    public static func format(_ corrections: [String: String]) -> String {
        corrections
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    /// Text back to a dictionary, skipping anything that is not a pair.
    ///
    /// Lines without a colon are dropped rather than rejected: this editor
    /// commits as you type, so a half-typed line exists on nearly every
    /// keystroke and must not throw away the rest of the list.
    public static func parse(_ text: String) -> [String: String] {
        var corrections: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // maxSplits 1: the replacement may itself contain a colon, and only
            // the first separates the pair.
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let misheard = parts[0].trimmingCharacters(in: .whitespaces)
            let correct = parts[1].trimmingCharacters(in: .whitespaces)
            guard !misheard.isEmpty, !correct.isEmpty else { continue }
            corrections[misheard] = correct
        }
        return corrections
    }
}

/// The vocabulary list's one-term-per-line format.
public enum VocabularyText {

    public static func format(_ terms: [String]) -> String {
        terms.joined(separator: "\n")
    }

    public static func parse(_ text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
