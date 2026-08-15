import AppKit
import Foundation

/// Optional start/stop feedback (legacy-python/daemon.py:248).
///
/// `NSSound` rather than shelling out to `afplay`: spawning a subprocess is
/// banned under the sandbox (APP_STORE.md §1), and it was always a heavy way
/// to play a system alert anyway.
public enum Sounds {

    private static let startPath = "/System/Library/Sounds/Tink.aiff"
    private static let stopPath = "/System/Library/Sounds/Pop.aiff"
    private static let unavailablePath = "/System/Library/Sounds/Basso.aiff"

    /// Held because `NSSound` stops when its last reference goes away, which
    /// for a fire-and-forget play means silence.
    nonisolated(unsafe) private static var start: NSSound?
    nonisolated(unsafe) private static var stop: NSSound?
    nonisolated(unsafe) private static var unavailable: NSSound?

    public static func playStart() {
        play(&start, path: startPath)
    }

    public static func playStop() {
        play(&stop, path: stopPath)
    }

    /// The trigger key was pressed and refused — the model isn't ready.
    ///
    /// Basso, the system's own "that didn't work" sound, so a refused press
    /// is tellable from a broken key without anything appearing on screen.
    /// The start tone answering a press is the app's whole acknowledgement
    /// protocol; refusing in total silence broke it exactly when the user
    /// most needed to know the press had registered.
    public static func playUnavailable() {
        play(&unavailable, path: unavailablePath)
    }

    private static func play(_ cache: inout NSSound?, path: String) {
        if cache == nil {
            cache = NSSound(contentsOfFile: path, byReference: true)
        }
        guard let sound = cache else { return }
        // Restart rather than ignore: two dictations in quick succession
        // should each be audible.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
