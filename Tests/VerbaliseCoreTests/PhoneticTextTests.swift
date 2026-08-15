import Foundation
import Testing

@testable import VerbaliseCore

/// The two text formats the Vocabulary pane edits.
///
/// Both round-trip -- what the user typed becomes structure and has to come
/// back looking like what they typed -- and both are parsed on a debounce while
/// typing, so every intermediate state of a half-written line goes through
/// them.
@Suite("Editable text formats")
struct PhoneticTextTests {

    // MARK: - Phonetic corrections

    @Test("A pair per line, round-tripping")
    func phoneticRoundTrips() {
        let corrections = ["ethanol": "FNOL", "sequel": "SQL"]
        let text = PhoneticText.format(corrections)
        #expect(text == "ethanol: FNOL\nsequel: SQL")
        #expect(PhoneticText.parse(text) == corrections)
    }

    @Test("Output is sorted, so the list does not reshuffle between openings")
    func phoneticIsSorted() {
        // A Dictionary has no order to preserve; hash order would move the
        // user's lines around every time they came back to the pane.
        let text = PhoneticText.format(["zebra": "Z", "apple": "A", "mango": "M"])
        #expect(text == "apple: A\nmango: M\nzebra: Z")
    }

    @Test("Only the first colon separates the pair")
    func phoneticSplitsOnce() {
        // The replacement may legitimately contain a colon.
        #expect(PhoneticText.parse("ratio: 3:1") == ["ratio": "3:1"])
    }

    @Test("Whitespace around either side is not part of the term")
    func phoneticTrims() {
        #expect(PhoneticText.parse("  ethanol  :   FNOL  ") == ["ethanol": "FNOL"])
    }

    @Test("A half-typed line is skipped, not fatal")
    func phoneticSkipsIncompleteLines() {
        // This is the common case, not an edge case: the pane commits on a
        // debounce, so a line mid-typing is parsed on nearly every keystroke.
        // Dropping the rest of the user's list at that moment would be
        // catastrophic and invisible.
        let text = "ethanol: FNOL\nhalfway\nsequel: SQL"
        #expect(PhoneticText.parse(text) == ["ethanol": "FNOL", "sequel": "SQL"])
    }

    @Test("A pair with an empty side is skipped")
    func phoneticSkipsEmptySides() {
        #expect(PhoneticText.parse("ethanol:\n: FNOL\n  :  ").isEmpty)
    }

    @Test("Empty text is no corrections, not a correction of nothing")
    func phoneticEmpty() {
        #expect(PhoneticText.parse("").isEmpty)
        #expect(PhoneticText.parse("\n\n\n").isEmpty)
        #expect(PhoneticText.format([:]).isEmpty)
    }

    // MARK: - Vocabulary

    @Test("A term per line, round-tripping in the order given")
    func vocabularyRoundTrips() {
        // Unlike corrections, order is the user's and is preserved: this is an
        // array in the config, and reordering it would be an unasked-for edit.
        let terms = ["Anthropic", "FNOL", "Kubernetes"]
        let text = VocabularyText.format(terms)
        #expect(text == "Anthropic\nFNOL\nKubernetes")
        #expect(VocabularyText.parse(text) == terms)
    }

    @Test("Blank lines and stray whitespace are dropped")
    func vocabularyIgnoresBlanks() {
        #expect(VocabularyText.parse("  Anthropic \n\n   \n FNOL") == ["Anthropic", "FNOL"])
    }

    @Test("Empty text is an empty vocabulary")
    func vocabularyEmpty() {
        #expect(VocabularyText.parse("").isEmpty)
        #expect(VocabularyText.format([]).isEmpty)
    }

    @Test("A term containing a colon is left alone")
    func vocabularyKeepsColons() {
        // Vocabulary is not the corrections format and must not be parsed like
        // it -- these two editors sit next to each other in the same pane.
        #expect(VocabularyText.parse("re:invent") == ["re:invent"])
    }
}
