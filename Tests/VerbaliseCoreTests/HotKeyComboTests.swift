import Foundation
import Testing
@testable import VerbaliseCore

@Suite("Hot key combo parsing and display")
struct HotKeyComboTests {

    @Test("Wire format round-trips")
    func wireFormatRoundTrips() throws {
        for value in ["alt+d", "cmd+shift+9", "f6", "ctrl+alt+space", "cmd+ctrl+alt+shift+/"] {
            let combo = try #require(HotKeyCombo(configValue: value), "\(value) should parse")
            #expect(combo.configValue == value, "\(value) should survive the round trip")
        }
    }

    @Test("Modifier order is canonicalised on output")
    func modifierOrderCanonicalised() throws {
        // A hand-edited config shouldn't churn just because the modifiers were
        // typed in a different order.
        let combo = try #require(HotKeyCombo(configValue: "shift+cmd+9"))
        #expect(combo.configValue == "cmd+shift+9")
    }

    @Test("A bare letter is rejected; a bare function key is allowed")
    func bareKeyRules() {
        // "d alone triggers dictation" must be impossible to configure: it
        // would fire on every ordinary press of the letter.
        #expect(HotKeyCombo(configValue: "d") == nil)
        #expect(HotKeyCombo(configValue: "9") == nil)
        #expect(HotKeyCombo(configValue: "f6") != nil)
        #expect(HotKeyCombo(configValue: "f19") != nil)
    }

    @Test("Unknown modifiers and keys are rejected, not guessed at")
    func unknownPartsRejected() {
        #expect(HotKeyCombo(configValue: "hyper+d") == nil)
        #expect(HotKeyCombo(configValue: "alt+fn") == nil)
        #expect(HotKeyCombo(configValue: "alt+return") == nil)
        #expect(HotKeyCombo(configValue: "") == nil)
        #expect(HotKeyCombo(configValue: "+") == nil)
    }

    @Test("Display uses menu-bar glyphs in the platform order")
    func displayGlyphs() throws {
        #expect(try #require(HotKeyCombo(configValue: "alt+d")).displayName == "⌥D")
        #expect(try #require(HotKeyCombo(configValue: "cmd+shift+9")).displayName == "⇧⌘9")
        #expect(try #require(HotKeyCombo(configValue: "f6")).displayName == "F6")
        // Full house comes out control, option, shift, command -- the order
        // every macOS menu uses.
        #expect(
            try #require(HotKeyCombo(configValue: "cmd+ctrl+alt+shift+v")).displayName
            == "⌃⌥⇧⌘V"
        )
    }

    @Test("Every key in the table survives a name round trip")
    func keyTableRoundTrips() {
        for code in UInt16(0)...UInt16(130) {
            guard let name = HotKeyCombo.name(forKeyCode: code) else { continue }
            #expect(HotKeyCombo.keyCode(forName: name) == code, "\(name) should map back to \(code)")
        }
    }

    @Test("The default combo is Option+D")
    func defaultCombo() {
        #expect(HotKeyCombo.defaultCombo.configValue == "alt+d")
        #expect(Settings().hotKey == "alt+d")
        #expect(Settings().hotKeyCombo == HotKeyCombo.defaultCombo)
    }

    @Test("Settings decode and validate the hotkey")
    func settingsIntegration() throws {
        let s = try JSONDecoder().decode(
            Settings.self, from: Data(#"{"hotkey": "cmd+shift+9"}"#.utf8)
        )
        #expect(s.hotKeyCombo?.displayName == "⇧⌘9")
        #expect(s.validate().isValid)

        var bad = Settings()
        bad.hotKey = "d"
        let result = bad.validate()
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("hotkey 'd'") })
    }
}
