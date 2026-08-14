import Foundation

/// The dictation language, as offered in Settings.
///
/// Whisper handles around a hundred languages, but a hundred-item menu is
/// worse than useless for choosing between them. This is the subset it
/// transcribes well enough to recommend, plus whatever the config already
/// names -- a hand-edited `language: cy` must stay selected and selectable
/// rather than silently reading as something else.
public struct Language: Equatable, Sendable, Identifiable {

    /// The ISO code stored in the config, or `Language.automaticCode`.
    public let code: String
    public let name: String

    public var id: String { code }

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    /// Let Whisper work the language out from the audio.
    ///
    /// Stored as a real config value rather than an absent one, so the choice
    /// survives a round trip through a file whose other keys are all present.
    /// It costs a little accuracy on short clips, which is why it is not the
    /// default.
    public static let automaticCode = "auto"
    public static let automatic = Language(code: automaticCode, name: "Automatic")

    public var isAutomatic: Bool { code == Self.automaticCode }

    /// Ordered for a menu: automatic first, then alphabetical by name.
    public static let common: [Language] = [
        .automatic,
        Language(code: "en", name: "English"),
        Language(code: "ar", name: "Arabic"),
        Language(code: "zh", name: "Chinese"),
        Language(code: "nl", name: "Dutch"),
        Language(code: "fr", name: "French"),
        Language(code: "de", name: "German"),
        Language(code: "hi", name: "Hindi"),
        Language(code: "it", name: "Italian"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "pl", name: "Polish"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "ru", name: "Russian"),
        Language(code: "es", name: "Spanish"),
        Language(code: "tr", name: "Turkish"),
        Language(code: "uk", name: "Ukrainian"),
    ]

    /// Everything the picker should list, including a configured code that is
    /// not in the common set.
    ///
    /// The same rule as the trigger key picker: a value the config already
    /// holds must appear, or the menu shows nothing selected and the first
    /// click silently discards it.
    public static func pickerOptions(including code: String) -> [Language] {
        var options = common
        if !options.contains(where: { $0.code == code }) {
            options.append(Language(code: code, name: describe(code)))
        }
        return options
    }

    /// A display name for a code that is not in the common set.
    ///
    /// Asks the system first -- it knows far more languages than are worth
    /// listing -- and falls back to the bare code, which at least matches what
    /// is in the file.
    public static func describe(_ code: String) -> String {
        if code == automaticCode { return automatic.name }
        if let name = Locale.current.localizedString(forLanguageCode: code) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return code
    }

    public static func name(for code: String) -> String {
        common.first { $0.code == code }?.name ?? describe(code)
    }
}
