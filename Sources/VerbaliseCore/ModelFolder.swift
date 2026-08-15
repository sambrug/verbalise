import Foundation

/// Decides whether a model folder on disk is actually usable.
///
/// "Is the model downloaded" used to mean "does its folder exist" — and a
/// download interrupted by quitting the app leaves the folder existing and
/// unloadable. That combination wedged the app permanently: every load
/// trusted the folder, failed on the missing file, and nothing would ever
/// re-download because the folder "existed". (`ModelDownloader.cancel`
/// documents the same trap and cleans up after an explicit cancel; killing
/// the app mid-fetch has no such moment, so the check has to happen on the
/// reading side.)
public enum ModelFolder {

    /// The files WhisperKit refuses to load without, plus the model config.
    /// `TextDecoderContextPrefill.mlmodelc` and `generation_config.json` also
    /// ship but are optional to WhisperKit, and a folder must not be held
    /// hostage to optional files.
    static let requiredItems = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "config.json",
    ]

    /// Whether every file a load will demand is present.
    ///
    /// An existence check, not a content check: a file truncated mid-write
    /// still passes, so callers must still treat a failed load of a
    /// "complete" folder as grounds to re-download.
    public static func isComplete(_ folder: URL) -> Bool {
        requiredItems.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }
}
