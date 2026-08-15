import Foundation

/// Maps the three tiers to models Argmax actually publishes (plan §7).
///
/// Resolved against the live listing of `argmaxinc/whisperkit-coreml` on
/// 2026-08-14, not guessed.
///
/// The compressed builds are chosen deliberately for `fast` and `balanced`.
/// Argmax publishes both a full-precision folder and a size-suffixed
/// compressed one for most variants, and the full-precision `turbo` is ~3 GB
/// against the compressed build's ~954 MB. For a menu bar app where nobody can
/// dictate until the download finishes, a third of the download for marginally
/// lower accuracy is the right trade. `accurate` is the exception: it exists
/// precisely for people who will wait.
extension TranscriptionModel {

    /// The WhisperKit model folder name.
    ///
    /// Non-optional now that every tier maps: the old eight-key set had
    /// `distil-medium`, which Argmax does not publish in any form and which
    /// had to be surfaced as permanently unavailable. Collapsing to three
    /// tiers removed that dead entry rather than leaving it greyed out.
    public var whisperKitModelName: String {
        switch self {
        case .fast: "openai_whisper-small_216MB"
        case .balanced: "openai_whisper-large-v3_turbo_954MB"
        case .accurate: "openai_whisper-large-v3"
        }
    }
}
