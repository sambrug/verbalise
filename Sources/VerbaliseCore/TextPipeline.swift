import Foundation

/// Post-processing between transcription and insertion, ported from
/// legacy-python/daemon.py:98-185 and :534. Pure functions: no state, no I/O, no actors.
///
/// Order matters and matches the Python: hallucination cleaning, then phonetic
/// corrections, then insert. Cleaning first means a correction can never
/// resurrect text that cleaning decided to drop.
public enum TextPipeline {

    // MARK: - Patterns

    /// Whisper learned these from YouTube/subtitle training data: on silence at
    /// the end of audio it fills with "outro" phrases, and uses "..." the way
    /// subtitles do for hesitation or unclear audio.
    ///
    /// Ported verbatim from TRAILING_HALLUCINATION_PATTERNS (legacy-python/daemon.py:75).
    /// All are anchored to the end of the string and case-insensitive.
    static let trailingHallucinationPatterns: [NSRegularExpression] = [
        #"\s*\bthanks for watching\b[\.\,\!\?]*\s*$"#,
        #"\s*\bthank you\b[\.\,\!\?]*\s*$"#,
        #"\s*\bthanks\b[\.\,\!\?]*\s*$"#,
        #"\s*\b(please |like and )?subscribe\b[\.\,\!\?]*\s*$"#,
        #"\s*\bbye(\s+for now)?\b[\.\,\!\?]*\s*$"#,
        #"\s*\bsee you (next time|in the next video)\b[\.\,\!\?]*\s*$"#,
        // 3+ consecutive ASCII dots at the end: an ellipsis hallucination,
        // since a real sentence-ending period cannot repeat.
        #"\s*\.{3,}\s*$"#,
        // Trailing unicode horizontal ellipsis, any count.
        #"\s*…+\s*$"#,
        // Multiple whitespace-separated dot/ellipsis groups at the end.
        // Catches ". . .", "... ... ...", " . … ." and "Hello there. ..."
        // while leaving a real sentence's final period intact -- the leading
        // \s+ means a period attached to a word is never consumed.
        #"(?:\s+[\.…]+){2,}\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static let punctuationOnly =
        try! NSRegularExpression(pattern: #"^[\s\.\,\!\?…]*$"#)

    /// Trailing sentence-ending punctuation, optionally followed by a closing
    /// quote or bracket, at the very end of a string (legacy-python/daemon.py:161).
    static let trailingSentenceEnd =
        try! NSRegularExpression(pattern: #"[.!?]+(['")\]]*)$"#)

    // MARK: - Repetition loop detection

    /// Detects Whisper's stuck-token repetition bug (legacy-python/daemon.py:98).
    ///
    /// The model occasionally falls into a decoding loop and emits the same
    /// word dozens or hundreds of times ("Region Region Region ..."). Two
    /// signals, either of which is conclusive:
    ///   - 8+ identical words in a row, which no natural speech produces
    ///   - 15+ words total where the most common word is more than half of them
    public static func looksLikeRepetitionLoop(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 8 else { return false }

        var longestRun = 1
        var currentRun = 1
        for i in 1..<words.count {
            if words[i] == words[i - 1] {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 1
            }
        }
        if longestRun >= 8 { return true }

        var counts: [String: Int] = [:]
        for word in words { counts[word, default: 0] += 1 }
        guard let mostCommon = counts.values.max() else { return false }

        return words.count >= 15 && Double(mostCommon) / Double(words.count) > 0.5
    }

    // MARK: - Hallucination cleaning

    /// Strips trailing hallucination phrases and ellipsis runs, and drops the
    /// text entirely when it looks like a repetition loop (legacy-python/daemon.py:132).
    ///
    /// Returns "" when the result is empty, punctuation-only, or a repetition
    /// loop; the caller treats that as "no transcription" and types nothing.
    public static func cleanHallucinations(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        if looksLikeRepetitionLoop(text) { return "" }

        var cleaned = text
        var changed = true
        // Loop because Whisper stacks them, e.g. "... thank you. ..." -- one
        // pass would strip the ellipsis and leave the "thank you" behind.
        while changed {
            changed = false
            for pattern in trailingHallucinationPatterns {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                let new = pattern.stringByReplacingMatches(
                    in: cleaned, options: [], range: range, withTemplate: ""
                )
                if new != cleaned {
                    cleaned = new
                    changed = true
                }
            }
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        let range = NSRange(cleaned.startIndex..., in: cleaned)
        if punctuationOnly.firstMatch(in: cleaned, options: [], range: range) != nil {
            return ""
        }
        return cleaned
    }

    // MARK: - Non-speech annotations

    /// Square-bracketed annotations: `[BLANK_AUDIO]`, `[MUSIC]`, `[INAUDIBLE]`.
    static let bracketedAnnotation =
        try! NSRegularExpression(pattern: #"\[[^\]]*\]"#)

    /// A parenthesised group and its contents, examined before removal.
    static let parenthesisedGroup =
        try! NSRegularExpression(pattern: #"\(([^)]*)\)"#)

    /// Music note runs and anything between a matched pair: `♪ la la la ♪`.
    static let musicNotes =
        try! NSRegularExpression(pattern: #"[♪♫][^♪♫]*[♪♫]|[♪♫]"#)

    static let repeatedWhitespace =
        try! NSRegularExpression(pattern: #"\s{2,}"#)

    /// Removes the caption conventions Whisper reproduces for non-speech sound.
    ///
    /// Not a hallucination in the usual sense and not a bug: Whisper was
    /// trained on subtitle data, which annotates audio that is not speech.
    /// So it writes `[BLANK_AUDIO]` for silence, and describes what it hears
    /// -- a fan becomes `(air whooshing)`, exactly as a captioner would write
    /// it. Correct behaviour for subtitling, useless when the output is being
    /// typed into someone's document.
    ///
    /// **This has no counterpart in the Python app**, which never filtered
    /// these. Kept separate from `cleanHallucinations` for that reason: that
    /// function is verified line by line against the Python's output, and
    /// folding a new rule into it would break the comparison that makes the
    /// port trustworthy.
    ///
    /// Brackets and music notes go unconditionally -- neither survives dictated
    /// speech. Parentheses are treated more carefully, because a speaker really
    /// can dictate a parenthetical aside and deleting it would be far worse
    /// than leaving a stray `(coughs)` in. Only short groups with no sentence
    /// punctuation are removed, which is the shape every sound annotation takes
    /// and which a spoken aside almost never does.
    public static func stripNonSpeechAnnotations(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        guard text.contains("[") || text.contains("(")
                || text.contains("♪") || text.contains("♫")
        else { return text }

        var result = replacingMatches(of: bracketedAnnotation, in: text, with: " ")
        result = replacingMatches(of: musicNotes, in: result, with: " ")
        result = removingSoundAnnotationParentheses(from: result)

        result = replacingMatches(of: repeatedWhitespace, in: result, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How many words a parenthesised group may hold and still read as a sound
    /// annotation rather than as something the speaker said.
    static let maximumAnnotationWords = 5

    private static func removingSoundAnnotationParentheses(from text: String) -> String {
        let full = NSRange(text.startIndex..., in: text)
        var result = text

        // Back to front, so each removal leaves earlier ranges valid.
        for match in parenthesisedGroup.matches(in: text, options: [], range: full).reversed() {
            guard let whole = Range(match.range, in: text),
                  let inner = Range(match.range(at: 1), in: text)
            else { continue }

            guard looksLikeSoundAnnotation(String(text[inner])) else { continue }
            result.replaceSubrange(whole, with: " ")
        }
        return result
    }

    /// Short, and not a sentence. "(air whooshing)" and "(door closes)" pass;
    /// "(and this is the part I meant, incidentally)" does not.
    static func looksLikeSoundAnnotation(_ inner: String) -> Bool {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard !trimmed.contains(where: { ".!?".contains($0) }) else { return false }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        return words.count <= maximumAnnotationWords
    }

    private static func replacingMatches(
        of regex: NSRegularExpression, in text: String, with template: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    // MARK: - Streaming chunk joining

    /// Joins per-chunk streaming transcripts into one continuous text
    /// (legacy-python/daemon.py:164).
    ///
    /// Each chunk is transcribed independently, so Whisper has no idea a chunk
    /// boundary sits mid-recording. It often closes a chunk with "." purely
    /// because the audio was cut at a pause, not because the speaker finished a
    /// sentence -- and it gets the *next* chunk's casing right (lowercase,
    /// clearly a continuation) while leaving that spurious full stop behind.
    /// A trailing sentence end followed by a lowercase start is therefore a
    /// reliable signal of a false split, and the punctuation is dropped.
    public static func joinStreamingChunks(_ chunks: [String]) -> String {
        let parts = chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return "" }

        var joined = first
        for next in parts.dropFirst() {
            if next.first?.isLowercase == true {
                let range = NSRange(joined.startIndex..., in: joined)
                joined = trailingSentenceEnd.stringByReplacingMatches(
                    in: joined, options: [], range: range, withTemplate: "$1"
                )
            }
            joined = "\(joined) \(next)"
        }
        return joined
    }

    // MARK: - Phonetic corrections

    /// Whole-word, case-insensitive replacement of misheard terms
    /// (legacy-python/daemon.py:534).
    ///
    /// The replacement is written verbatim so the user controls final casing
    /// (the motivating example being "ethanol" -> "FNOL").
    ///
    /// Corrections are an *ordered* array rather than a dictionary: they are
    /// applied in sequence and can overlap, so iteration order is part of the
    /// behaviour. Python dicts preserve insertion order and a Swift Dictionary
    /// does not, so the order is made explicit here instead of left to chance.
    public static func applyPhoneticCorrections(
        _ text: String,
        corrections: [(misheard: String, correct: String)]
    ) -> String {
        guard !text.isEmpty, !corrections.isEmpty else { return text }

        var result = text
        for (misheard, correct) in corrections {
            guard !misheard.isEmpty else { continue }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: misheard) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }

            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: correct)
            )
        }
        return result
    }
}
