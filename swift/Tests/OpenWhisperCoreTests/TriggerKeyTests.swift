import Testing
@testable import OpenWhisperCore

@Suite("Trigger key parsing and matching")
struct TriggerKeyTests {

    @Test("Every Python key name parses")
    func allPythonKeyNamesParse() {
        // The exact set from daemon.py:188. A rename here silently breaks
        // existing user configs, so pin the wire format.
        let names = ["shift_r", "shift_l", "ctrl_r", "ctrl_l", "alt_r", "alt_l", "cmd_r"]
        for name in names {
            #expect(TriggerKey(rawValue: name) != nil, "\(name) should parse")
        }
        #expect(TriggerKey.allCases.count == names.count)
    }

    @Test("Single key round-trips through config form")
    func singleKeyRoundTrip() {
        let combo = TriggerCombo(configValue: "shift_r")
        #expect(combo?.keys == [.shiftR])
        #expect(combo?.configValue == "shift_r")
    }

    @Test("Combo joined with + parses in order")
    func comboParses() {
        let combo = TriggerCombo(configValue: "alt_r+shift_r")
        #expect(combo?.keys == [.altR, .shiftR])
        #expect(combo?.configValue == "alt_r+shift_r")
    }

    @Test("Whitespace around combo parts is tolerated")
    func comboTolerantOfSpaces() {
        #expect(TriggerCombo(configValue: " alt_r + shift_r ")?.keys == [.altR, .shiftR])
    }

    @Test("Unknown key name fails rather than silently falling back")
    func unknownKeyRejected() {
        // Must be nil, not a default: the caller turns this into a visible
        // configError so a typo never leaves the user with a dead trigger key
        // and no explanation.
        #expect(TriggerCombo(configValue: "shift_middle") == nil)
        #expect(TriggerCombo(configValue: "alt_r+nope") == nil)
        #expect(TriggerCombo(configValue: "") == nil)
        #expect(TriggerCombo(configValue: "+") == nil)
    }

    @Test("Left and right shift are distinguishable by device mask")
    func leftRightShiftAreDistinct() {
        // This is the whole reason the device-dependent bits are used instead
        // of CGEventFlags.maskShift, which is identical for both keys.
        #expect(TriggerKey.shiftL.deviceMask != TriggerKey.shiftR.deviceMask)

        let rightOnly = TriggerKey.shiftR.deviceMask
        #expect(TriggerCombo(keys: [.shiftR]).isFullyHeld(flags: rightOnly))
        #expect(!TriggerCombo(keys: [.shiftL]).isFullyHeld(flags: rightOnly))
    }

    @Test("Every key has a unique keycode and mask")
    func keycodesAndMasksAreUnique() {
        let codes = Set(TriggerKey.allCases.map(\.keyCode))
        let masks = Set(TriggerKey.allCases.map(\.deviceMask))
        #expect(codes.count == TriggerKey.allCases.count)
        #expect(masks.count == TriggerKey.allCases.count)
    }

    @Test("Combo requires every key held, not just one")
    func comboNeedsAllKeys() {
        let combo = TriggerCombo(keys: [.altR, .shiftR])
        let onlyShift = TriggerKey.shiftR.deviceMask
        let both = TriggerKey.shiftR.deviceMask | TriggerKey.altR.deviceMask

        #expect(!combo.isFullyHeld(flags: onlyShift))
        #expect(combo.isFullyHeld(flags: both))
    }

    @Test("involves(keyCode:) ignores unrelated modifier traffic")
    func involvesFiltersUnrelatedKeys() {
        let combo = TriggerCombo(keys: [.shiftR])
        #expect(combo.involves(keyCode: TriggerKey.shiftR.keyCode))
        #expect(!combo.involves(keyCode: TriggerKey.shiftL.keyCode))
        #expect(!combo.involves(keyCode: TriggerKey.cmdR.keyCode))
    }
}
