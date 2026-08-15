import Foundation
import Testing

@testable import VerbaliseCore

/// The language picker's list, and what "Automatic" means downstream.
@Suite("Language")
struct LanguageTests {

    @Test("Automatic leads the list, then the rest alphabetically")
    func automaticIsFirst() {
        #expect(Language.common.first == .automatic)
        // English second by exception: it is the default and the majority
        // case, and hunting for it between Dutch and French is a worse list.
        #expect(Language.common.dropFirst().first?.code == "en")
        let rest = Language.common.dropFirst(2).map(\.name)
        #expect(rest == rest.sorted())
    }

    @Test("Every code appears once")
    func codesAreUnique() {
        let codes = Language.common.map(\.code)
        #expect(Set(codes).count == codes.count)
    }

    @Test("A configured language that is not in the common set is still offered")
    func handEditedCodeIsIncluded() {
        // Same rule as the trigger key picker: a value the config already
        // holds has to appear, or the menu shows nothing selected and the
        // first click silently discards it.
        let options = Language.pickerOptions(including: "cy")
        #expect(options.contains { $0.code == "cy" })
        #expect(options.count == Language.common.count + 1)
    }

    @Test("A code already in the set is not duplicated")
    func knownCodeIsNotDuplicated() {
        let options = Language.pickerOptions(including: "fr")
        #expect(options.count == Language.common.count)
        #expect(options.filter { $0.code == "fr" }.count == 1)
    }

    @Test("An unknown code gets a real name where the system knows one")
    func unknownCodesAreNamed() {
        // Welsh is not in the common set but macOS can name it, which beats
        // showing "cy" in a menu.
        #expect(Language.describe("cy") != "cy")
        #expect(Language.describe("cy").first?.isUppercase == true)
    }

    @Test("A nonsense code falls back to itself rather than to nothing")
    func nonsenseCodeFallsBack() {
        // Matching what is in the file is more useful than an empty row.
        #expect(!Language.name(for: "zzzz").isEmpty)
    }

    // MARK: - What it means to the engine

    @Test("Automatic asks Whisper to detect, rather than requesting a language")
    func automaticMeansNoLanguage() {
        var settings = Settings()
        settings.language = Language.automaticCode
        #expect(settings.effectiveLanguage == nil)
    }

    @Test("A chosen language is passed through unchanged")
    func chosenLanguageIsRequested() {
        var settings = Settings()
        settings.language = "fr"
        #expect(settings.effectiveLanguage == "fr")
    }

    @Test("The default is English, not automatic")
    func defaultIsEnglish() {
        // Detection costs accuracy on short phrases, which is most dictations.
        #expect(Settings().effectiveLanguage == "en")
    }

    @Test("\"auto\" survives a round trip through the config")
    func automaticPersists() throws {
        var settings = Settings()
        settings.language = Language.automaticCode
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded.language == Language.automaticCode)
        #expect(decoded.effectiveLanguage == nil)
    }
}
