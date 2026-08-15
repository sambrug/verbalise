import Foundation

/// Decides when to drop the speech model out of memory (legacy-python/daemon.py:843-903).
///
/// The model is large, and a menu bar app that sits idle all afternoon holding
/// it is a bad citizen. It is unloaded after a period with no dictation and
/// reloaded transparently on the next one, with the pill showing
/// "Recording… (waking speech model)" so the extra second is explained rather
/// than looking like a hang.
///
/// Ported with the fixed semantics from commit c049892. WhisperKit on the ANE
/// may make the reload nearly free, but the setting stays either way: users
/// who never dictate for hours still get their memory back.
public actor ModelLifecycle {

    private let clock: any MonotonicClock
    private var lastActivity: Double
    private let onUnload: @Sendable () -> Void

    public private(set) var isLoaded = false

    public init(
        clock: any MonotonicClock = SystemClock(),
        onUnload: @escaping @Sendable () -> Void = {}
    ) {
        self.clock = clock
        self.lastActivity = clock.now
        self.onUnload = onUnload
    }

    /// Marks the model as in memory and resets the idle timer.
    public func noteLoaded() {
        isLoaded = true
        lastActivity = clock.now
    }

    /// Any dictation activity resets the idle timer.
    public func noteActivity() {
        lastActivity = clock.now
    }

    public func noteUnloaded() {
        isLoaded = false
    }

    /// Seconds since the last dictation activity. Exposed for the log line.
    public var idleSeconds: Double {
        clock.now - lastActivity
    }

    /// Unloads if the model has been idle past the threshold.
    /// Returns whether it actually unloaded.
    ///
    /// - Parameters:
    ///   - idleMinutes: `model_idle_unload_minutes`; 0 means never unload.
    ///   - isRecording: unloading mid-dictation would strand the recording, so
    ///     the check is skipped entirely while one is in progress.
    @discardableResult
    public func maybeUnload(idleMinutes: Int, isRecording: Bool) -> Bool {
        guard idleMinutes > 0 else { return false }
        guard isLoaded else { return false }
        guard !isRecording else { return false }

        let threshold = Double(idleMinutes) * 60
        guard idleSeconds > threshold else { return false }

        log("model: idle \(Int(idleSeconds / 60))m, unloading")
        isLoaded = false
        onUnload()
        return true
    }
}
