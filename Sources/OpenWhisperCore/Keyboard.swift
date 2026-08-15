import CoreGraphics
import Foundation

/// Seam for everything that synthesises key events, so the recovery tests can
/// assert what would have been typed without touching the real keyboard
/// (`FakeKeyboard` in tests/test_recovery.py).
public protocol KeyboardPosting: Sendable {
    /// Types `text` directly as Unicode key events. No clipboard involvement.
    func typeUnicode(_ text: String)
    /// Posts Cmd+V.
    func postPasteShortcut()
}

/// Real implementation, over `CGEventKeyboardSetUnicodeString`.
///
/// Needs the PostEvent TCC grant at runtime; there is no entitlement for it
/// (APP_STORE.md §6).
public struct SystemKeyboard: KeyboardPosting {

    /// Matches the Python fast path (daemon.py:982), which posts in 20-character
    /// chunks rather than one event per character.
    private static let chunkSize = 20

    /// Gap between chunks. APP_STORE.md flags the Python version's *absence* of
    /// this as a bug: posted events go onto the target app's queue faster than
    /// a busy app drains it, and the tail of a long string can arrive out of
    /// order or be dropped entirely. A couple of milliseconds is invisible to
    /// the user and enough for the receiver to keep up.
    private static let interChunkDelay: TimeInterval = 0.002

    private let virtualKey: CGKeyCode = 0
    private let pasteKeyCode: CGKeyCode = 9 // 'v'

    public init() {}

    public func typeUnicode(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        for (index, chunk) in Self.chunks(of: text).enumerated() {
            if index > 0 {
                Thread.sleep(forTimeInterval: Self.interChunkDelay)
            }
            var utf16 = Array(chunk.utf16)
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
            else { continue }

            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    public func postPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Splits into runs of at most `chunkSize` UTF-16 code units, without ever
    /// cutting a grapheme. Chunking the UTF-16 array directly would split
    /// surrogate pairs and corrupt anything outside the BMP -- emoji, and some
    /// CJK -- so the split happens on `Character` boundaries.
    static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentLength = 0

        for character in text {
            let length = character.utf16.count
            if currentLength + length > chunkSize, !current.isEmpty {
                result.append(current)
                current = ""
                currentLength = 0
            }
            current.append(character)
            currentLength += length
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
