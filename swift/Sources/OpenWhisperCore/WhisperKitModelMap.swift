import Foundation

/// Maps the eight config keys to the models Argmax actually publishes
/// (plan §7).
///
/// Resolved against the live listing of `argmaxinc/whisperkit-coreml` on
/// 2026-08-14. The published folders relevant here:
///
///     openai_whisper-tiny              openai_whisper-medium
///     openai_whisper-base              openai_whisper-large-v3
///     openai_whisper-small             openai_whisper-large-v3_turbo
///     distil-whisper_distil-large-v3
///
/// `distil-medium.en` is **not published** in any form -- exactly the gap plan
/// §7 anticipated. It stays in the menu, greyed out with a tooltip, rather than
/// silently vanishing: a user whose config names it deserves to see why it
/// stopped working rather than watch the app quietly pick something else.
///
/// This lives in Core, with no WhisperKit import, so the menu can ask what is
/// available without pulling the speech stack into the UI layer or the tests.
extension TranscriptionModel {

    /// The WhisperKit model folder name, or nil when nothing equivalent is
    /// published.
    public var whisperKitModelName: String? {
        switch self {
        case .tiny: "openai_whisper-tiny"
        case .base: "openai_whisper-base"
        case .small: "openai_whisper-small"
        case .medium: "openai_whisper-medium"
        case .large: "openai_whisper-large-v3"
        case .turbo: "openai_whisper-large-v3_turbo"
        case .distilLarge: "distil-whisper_distil-large-v3"
        case .distilMedium: nil
        }
    }

    public var isAvailable: Bool { whisperKitModelName != nil }

    /// Menu tooltip for an unavailable model.
    public var unavailableReason: String? {
        guard !isAvailable else { return nil }
        return "Not available: Argmax publishes no CoreML build of \(rawValue)."
    }

    /// Models that can actually be selected.
    public static var availableCases: [TranscriptionModel] {
        allCases.filter(\.isAvailable)
    }
}
