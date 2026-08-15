import Foundation
import Testing
@testable import OpenWhisperCore

/// Scenario group 9 from tests/test_recovery.py: never paste the user's old
/// clipboard, and never clobber something they copied.
@Suite("Clipboard insertion path")
struct TextInserterTests {

    /// Comfortably over the 80-character fast-typing threshold.
    static let long = "This is a long dictation, well over the fast-typing threshold, so it takes the clipboard path."

    static func settings(
        releaseDelay: Double = 0,
        restoreDelay: Double = 0,
        fastTypingMaxChars: Int = 80,
        fastTypingEnabled: Bool = true
    ) -> Settings {
        var s = Settings()
        s.releaseDelay = releaseDelay
        s.advanced.clipboardRestoreDelay = restoreDelay
        s.advanced.fastTypingMaxChars = fastTypingMaxChars
        s.advanced.fastTypingEnabled = fastTypingEnabled
        return s
    }

    // MARK: - Short text

    @Test("short text: unicode path, clipboard untouched")
    func shortTextUsesUnicodePath() async {
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        let inserter = TextInserter(keyboard: keyboard, pasteboard: clipboard)

        let outcome = await inserter.insert("short one", settings: Self.settings())

        #expect(outcome.path == .typed)
        #expect(keyboard.typed == ["short one"])
        #expect(keyboard.pasteCount == 0)
        #expect(clipboard.writes.isEmpty)
        #expect(clipboard.value == "PREVIOUS CLIPBOARD")
    }

    @Test("fast typing disabled sends even short text via the clipboard")
    func fastTypingDisabled() async {
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        let inserter = TextInserter(keyboard: keyboard, pasteboard: clipboard)

        let outcome = await inserter.insert(
            "short one", settings: Self.settings(fastTypingEnabled: false)
        )

        #expect(outcome.path == .pasted)
        #expect(keyboard.typed.isEmpty)
        #expect(keyboard.pasteCount == 1)
    }

    @Test("empty text does nothing at all")
    func emptyTextIgnored() async {
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        let inserter = TextInserter(keyboard: keyboard, pasteboard: clipboard)

        #expect(await inserter.insert("", settings: Self.settings()).path == .notInserted)
        #expect(keyboard.typed.isEmpty)
        #expect(clipboard.writes.isEmpty)
    }

    // MARK: - Refused write

    @Test("clipboard refused: no paste sent, user's clipboard untouched")
    func refusedWriteDoesNotPaste() async {
        // Pasting now would insert the user's own clipboard into their
        // document, which is worse than inserting nothing.
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard(refuseWrites: true)
        let inserter = TextInserter(keyboard: keyboard, pasteboard: clipboard)

        let outcome = await inserter.insert(Self.long, settings: Self.settings())

        #expect(outcome.path == .notInserted)
        #expect(outcome.warning != nil)
        #expect(keyboard.pasteCount == 0)
        #expect(clipboard.value == "PREVIOUS CLIPBOARD")
    }

    @Test("a refused write is retried before giving up")
    func refusedWriteIsRetried() async {
        // The pasteboard server is often only briefly busy, so a single
        // failure must not be treated as final.
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        // Fail the first two attempts, succeed on the third.
        clipboard.refuseFirstWrites = 2
        let inserter = TextInserter(keyboard: keyboard, pasteboard: clipboard)

        let outcome = await inserter.insert(Self.long, settings: Self.settings())

        #expect(outcome.path == .pasted)
        #expect(keyboard.pasteCount == 1)
        #expect(clipboard.writes == [Self.long], "only the successful write should land")
    }

    @Test("giving up takes the full retry budget, not the first failure")
    func retriesAreExhaustedBeforeGivingUp() async {
        // One transient refusal must not lose the dictation, so the budget has
        // to actually be spent before the paste is abandoned.
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        clipboard.refuseFirstWrites = 99
        let inserter = TextInserter(keyboard: keyboard, pasteboard: clipboard)

        let outcome = await inserter.insert(Self.long, settings: Self.settings())

        #expect(outcome.path == .notInserted)
        #expect(keyboard.pasteCount == 0)
        #expect(clipboard.value == "PREVIOUS CLIPBOARD")
    }

    // MARK: - Hijack before paste

    @Test("clipboard hijacked before paste: no paste sent")
    func hijackBeforePasteAborts() async {
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()

        // Another app takes the pasteboard in the window between our verified
        // write and the keystroke.
        clipboard.onRead = { [weak clipboard] in
            guard let clipboard, clipboard.value == Self.long else { return }
            clipboard.set("SOMETHING ELSE COPIED")
        }

        let inserter = TextInserter(keyboard: keyboard, pasteboard: clipboard)
        let outcome = await inserter.insert(Self.long, settings: Self.settings())

        #expect(outcome.path == .notInserted)
        #expect(outcome.warning != nil)
        #expect(keyboard.pasteCount == 0)
    }

    // MARK: - Happy path

    @Test("normal paste: Cmd+V sent with our text on the clipboard")
    func normalPasteSendsShortcut() async {
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        let inserter = TextInserter(keyboard: keyboard, pasteboard: clipboard)

        let outcome = await inserter.insert(Self.long, settings: Self.settings())

        #expect(outcome.path == .pasted)
        #expect(keyboard.pasteCount == 1)
        #expect(clipboard.writes.first == Self.long)
        // Still ours immediately after: restore must not have raced the paste.
        #expect(clipboard.value == Self.long)
    }

    @Test("normal paste: previous clipboard restored after the delay")
    func previousClipboardRestored() async throws {
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        let inserter = TextInserter(keyboard: keyboard, pasteboard: clipboard)

        _ = await inserter.insert(Self.long, settings: Self.settings(restoreDelay: 0.2))

        #expect(clipboard.value == Self.long, "must still be ours right after the paste")
        try await waitUntil(timeout: .seconds(2)) { clipboard.value == "PREVIOUS CLIPBOARD" }
        #expect(clipboard.value == "PREVIOUS CLIPBOARD")
    }

    @Test("restore delay of 0 leaves the dictation on the clipboard")
    func zeroRestoreDelayKeepsDictation() async throws {
        // Documented as "never restore", not "restore immediately".
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        let inserter = TextInserter(keyboard: keyboard, pasteboard: clipboard)

        _ = await inserter.insert(Self.long, settings: Self.settings(restoreDelay: 0))

        try await Task.sleep(for: .milliseconds(300))
        #expect(clipboard.value == Self.long)
    }

    @Test("user copy during the restore window: not clobbered")
    func userCopyDuringWindowSurvives() async throws {
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        let inserter = TextInserter(keyboard: keyboard, pasteboard: clipboard)

        _ = await inserter.insert(Self.long, settings: Self.settings(restoreDelay: 0.3))

        // The user copies something while the restore is still pending.
        clipboard.set("USER COPIED THIS WHILE WAITING")

        try await Task.sleep(for: .milliseconds(600))
        #expect(
            clipboard.value == "USER COPIED THIS WHILE WAITING",
            "the user's copy must win over our restore"
        )
    }
}
