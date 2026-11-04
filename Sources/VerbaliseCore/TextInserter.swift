import Foundation

/// Puts transcribed text into whatever app has focus (legacy-python/daemon.py:982-1073).
///
/// Two paths. Short text is typed directly as Unicode key events and never
/// touches the clipboard. Longer text goes via the clipboard and Cmd+V, because
/// typing hundreds of characters one event at a time is slow and drops
/// characters under load.
///
/// The clipboard path is where the care is. Two ways it used to insert the
/// *wrong* text: a pasteboard write that silently did not take, leaving the
/// user's previous clipboard in place for Cmd+V to paste; and restoring the old
/// clipboard before the focused app had actually read the pasteboard.
public actor TextInserter {

    public struct Outcome: Equatable, Sendable {
        public enum Path: Equatable, Sendable {
            case typed
            case pasted
            /// Clipboard mode: the transcript is on the clipboard and the
            /// user pastes it themselves. No key event was synthesised.
            case copied
            case notInserted
        }
        public var path: Path
        /// Warning to surface in the menu bar, using the Python's exact
        /// wording (legacy-python/daemon.py:1037-1046) so it reads the same to the user.
        public var warning: String?
    }

    private let keyboard: any KeyboardPosting
    private let pasteboard: any Pasteboard
    private let clock: any MonotonicClock

    /// Retry budget for a busy pasteboard server (legacy-python/daemon.py:311).
    private let writeAttempts = 3
    private let writeRetryGap = Duration.milliseconds(80)

    public init(
        keyboard: any KeyboardPosting,
        pasteboard: any Pasteboard,
        clock: any MonotonicClock = SystemClock()
    ) {
        self.keyboard = keyboard
        self.pasteboard = pasteboard
        self.clock = clock
    }

    /// Inserts `text`, choosing the path from `settings`.
    @discardableResult
    public func insert(_ text: String, settings: Settings) async -> Outcome {
        guard !text.isEmpty else { return Outcome(path: .notInserted, warning: nil) }

        // Clipboard mode never touches the keyboard: the transcript is
        // copied, verified, and left there for the user's own Cmd+V. No
        // restore either -- the clipboard *is* the delivery vehicle, and
        // snatching the text back on a timer would be a race against the
        // user's hands.
        if settings.insertionMode == .clipboard {
            guard await writeVerified(text) else {
                log("clipboard: write refused after \(writeAttempts) attempts")
                return Outcome(
                    path: .notInserted,
                    warning: "Clipboard unavailable — text not copied. It's in Recent Transcripts."
                )
            }
            return Outcome(path: .copied, warning: nil)
        }

        if settings.advanced.fastTypingEnabled,
           text.count <= settings.advanced.fastTypingMaxChars {
            keyboard.typeUnicode(text)
            return Outcome(path: .typed, warning: nil)
        }
        return await pasteViaClipboard(text, settings: settings)
    }

    private func pasteViaClipboard(_ text: String, settings: Settings) async -> Outcome {
        log("insertion: clipboard_begin release_delay_s=\(settings.releaseDelay) restore_delay_s=\(settings.advanced.clipboardRestoreDelay)")
        let previous = pasteboard.read()

        guard await writeVerified(text) else {
            // Not pasting is the safe failure. Sending Cmd+V now would paste
            // whatever is still on the clipboard -- the user's own content --
            // into their document. The text stays in Recent Transcripts.
            log("clipboard: write refused after \(writeAttempts) attempts, not pasting")
            return Outcome(
                path: .notInserted,
                warning: "Clipboard unavailable — text not pasted. It's in Recent Transcripts."
            )
        }

        let afterWrite = pasteboard.changeCount

        if settings.releaseDelay > 0 {
            try? await clock.sleep(for: .seconds(settings.releaseDelay))
        }

        // Re-check immediately before the keystroke. Another app can take the
        // pasteboard in the window between our write and the paste, and Cmd+V
        // would then insert their content into the user's document.
        guard pasteboard.read() == text else {
            log("clipboard: hijacked between write and paste, not pasting")
            return Outcome(
                path: .notInserted,
                warning: "Clipboard was changed by another app — text not pasted. It's in Recent Transcripts."
            )
        }

        keyboard.postPasteShortcut()

        if settings.advanced.clipboardRestoreDelay > 0 {
            await scheduleRestore(
                previous: previous,
                ourChangeCount: afterWrite,
                after: settings.advanced.clipboardRestoreDelay
            )
        }
        return Outcome(path: .pasted, warning: nil)
    }

    /// Writes with retries, confirming the pasteboard actually holds `text`.
    ///
    /// The pasteboard server refuses writes while busy -- just after another
    /// app or a Finder right-click+Copy touched it -- without raising, so an
    /// unchecked write is indistinguishable from a successful one until the
    /// wrong text lands in the user's document.
    private func writeVerified(_ text: String) async -> Bool {
        let started = clock.now
        for attempt in 1...writeAttempts {
            if pasteboard.write(text), pasteboard.read() == text {
                log("clipboard: write_verified attempts=\(attempt) elapsed_s=\(clock.now - started)")
                return true
            }
            if attempt < writeAttempts {
                try? await clock.sleep(for: writeRetryGap)
            }
        }
        return false
    }

    /// Restores the user's previous clipboard, unless they copied something in
    /// the meantime.
    ///
    /// The delay exists because the focused app reads the pasteboard whenever it
    /// gets round to processing our Cmd+V. Restoring too early makes a busy app
    /// paste the user's old clipboard instead of the dictation.
    ///
    /// The changeCount guard is the other half: if anything changed the
    /// pasteboard since our write, that was the user, and their copy must win.
    private func scheduleRestore(
        previous: String,
        ourChangeCount: Int,
        after delay: Double
    ) async {
        let pasteboard = self.pasteboard
        let clock = self.clock

        let trace = Diagnostics.context
        let sink = Diagnostics.sink
        Task.detached {
            await Diagnostics.$context.withValue(trace) {
                await Diagnostics.$sink.withValue(sink) {
                    try? await clock.sleep(for: .seconds(delay))

                    guard pasteboard.changeCount == ourChangeCount else {
                        log("clipboard: user copied during the restore window, leaving it alone")
                        return
                    }
                    let restored = pasteboard.write(previous)
                    log("clipboard: restore success=\(restored)")
                }
            }
        }
    }
}
