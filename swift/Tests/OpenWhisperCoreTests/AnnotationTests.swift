import Foundation
import Testing

@testable import OpenWhisperCore

/// Whisper's subtitle habits.
///
/// It was trained on caption data, so it annotates audio that is not speech:
/// `[BLANK_AUDIO]` for silence, and a description of whatever it hears. A fan
/// becomes "(air whooshing)". Right for subtitling, wrong when the output is
/// being typed into a document.
///
/// This has no Python counterpart, so unlike the rest of the pipeline it is
/// verified against intent rather than against the original app.
@Suite("Non-speech annotations")
struct AnnotationTests {

    // MARK: - Brackets

    @Test("Silence markers are removed")
    func blankAudioIsRemoved() {
        #expect(TextPipeline.stripNonSpeechAnnotations("[BLANK_AUDIO]").isEmpty)
        #expect(TextPipeline.stripNonSpeechAnnotations("[ Silence ]").isEmpty)
    }

    @Test("A marker around real speech leaves the speech")
    func bracketsAroundSpeech() {
        #expect(
            TextPipeline.stripNonSpeechAnnotations("[BLANK_AUDIO] Hello there.")
                == "Hello there."
        )
        #expect(
            TextPipeline.stripNonSpeechAnnotations("Hello there. [MUSIC]")
                == "Hello there."
        )
        #expect(
            TextPipeline.stripNonSpeechAnnotations("Book [INAUDIBLE] a table")
                == "Book a table"
        )
    }

    @Test("Music notation is removed, with whatever it wraps")
    func musicNotesAreRemoved() {
        #expect(TextPipeline.stripNonSpeechAnnotations("♪ la la la ♪").isEmpty)
        #expect(TextPipeline.stripNonSpeechAnnotations("♪").isEmpty)
        #expect(TextPipeline.stripNonSpeechAnnotations("Hello ♪♪ there") == "Hello there")
    }

    // MARK: - Parentheses, which are the risky ones

    @Test("A described sound is removed")
    func soundDescriptionsAreRemoved() {
        // The case Sam hit: a desk fan, transcribed the way a captioner writes
        // it.
        #expect(TextPipeline.stripNonSpeechAnnotations("(air whooshing)").isEmpty)
        #expect(TextPipeline.stripNonSpeechAnnotations("(coughs) Right, so") == "Right, so")
    }

    @Test("A spoken aside is kept")
    func spokenAsidesSurvive() {
        // Deleting something the user actually said is far worse than leaving
        // a stray "(coughs)" in, so anything sentence-shaped stays.
        let aside = "The report (and this is the part I actually meant, by the way) is late."
        #expect(TextPipeline.stripNonSpeechAnnotations(aside) == aside)
    }

    @Test("Length is what separates an annotation from an aside")
    func lengthIsTheBoundary() {
        #expect(TextPipeline.looksLikeSoundAnnotation("air whooshing"))
        #expect(TextPipeline.looksLikeSoundAnnotation("door closes in the distance"))
        #expect(!TextPipeline.looksLikeSoundAnnotation(
            "six words is one word too many"
        ))
    }

    @Test("Sentence punctuation marks it as speech")
    func punctuationMarksItAsSpeech() {
        #expect(!TextPipeline.looksLikeSoundAnnotation("really?"))
        #expect(!TextPipeline.looksLikeSoundAnnotation("yes. no"))
    }

    // MARK: - Leaving ordinary text alone

    @Test("Text with no annotations is returned untouched")
    func plainTextIsUntouched() {
        let text = "Move the meeting to Thursday at half past two."
        #expect(TextPipeline.stripNonSpeechAnnotations(text) == text)
        #expect(TextPipeline.stripNonSpeechAnnotations("").isEmpty)
    }

    @Test("Removal does not leave doubled spaces behind")
    func spacingIsTidiedUp() {
        #expect(
            TextPipeline.stripNonSpeechAnnotations("Hello [MUSIC] there")
                == "Hello there"
        )
    }

    // MARK: - Together with the rest of the pipeline

    @Test("An annotation-only transcript ends up as nothing to type")
    func annotationOnlyBecomesEmpty() {
        // The two run in sequence in DictationController: stripping can leave
        // only punctuation, and cleaning is what recognises that as "no
        // transcription".
        for raw in ["[BLANK_AUDIO]", "(air whooshing)", "♪♪♪", "[BLANK_AUDIO].", "( wind )..."] {
            let spoken = TextPipeline.stripNonSpeechAnnotations(raw)
            #expect(
                TextPipeline.cleanHallucinations(spoken).isEmpty,
                "\(raw) should leave nothing to type"
            )
        }
    }

    @Test("Real speech wrapped in annotations still gets typed")
    func speechSurvivesThePipeline() {
        let spoken = TextPipeline.stripNonSpeechAnnotations(
            "[BLANK_AUDIO] Send the invoice on Friday. (paper rustling)"
        )
        #expect(TextPipeline.cleanHallucinations(spoken) == "Send the invoice on Friday.")
    }
}
