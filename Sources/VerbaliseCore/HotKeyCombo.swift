import Foundation

/// A key-plus-modifiers shortcut for the App Store build's trigger.
///
/// The direct build watches modifier keys being held (`TriggerCombo` over an
/// event tap), which needs Input Monitoring -- the permission App Review
/// refuses on the Mac App Store. The store build instead registers a system
/// hotkey, and a registered hotkey must be a real key with modifiers (or a
/// bare function key); bare modifier holds cannot be expressed at all. This
/// type is that combo: parsing, wire format and display live here where the
/// tests run, while the Carbon registration itself stays in the app layer.
///
/// Wire format matches the trigger_key style: modifiers joined with `+` in
/// cmd, ctrl, alt, shift order, then the key name -- `alt+d`, `cmd+shift+9`,
/// `f6`. A combo with no modifier is valid only for function keys: a plain
/// letter would fire on ordinary typing.
public struct HotKeyCombo: Equatable, Sendable {

    /// Modifier set, kept as raw Carbon flag values so the app layer can hand
    /// them straight to registration without this module importing Carbon.
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        // Carbon's cmdKey / controlKey / optionKey / shiftKey.
        public static let command = Modifiers(rawValue: 0x0100)
        public static let shift = Modifiers(rawValue: 0x0200)
        public static let option = Modifiers(rawValue: 0x0800)
        public static let control = Modifiers(rawValue: 0x1000)
    }

    /// Carbon virtual keycode (US ANSI layout values).
    public let keyCode: UInt16
    public let modifiers: Modifiers

    /// Fails on a modifier-less combo unless the key is a function key --
    /// that rule is what keeps "d alone triggers dictation" impossible.
    public init?(keyCode: UInt16, modifiers: Modifiers) {
        guard Self.name(forKeyCode: keyCode) != nil else { return nil }
        if modifiers.isEmpty && !Self.isFunctionKey(keyCode) { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The store build's default. Option+D types "∂" when unclaimed, which
    /// nobody loses sleep over, and apps essentially never bind bare
    /// Option+letter shortcuts because they normally produce characters --
    /// so stealing it system-wide costs the least of any comfortable combo.
    public static let defaultCombo = HotKeyCombo(
        keyCode: 2, modifiers: .option
    )!

    // MARK: - Wire format

    public init?(configValue: String) {
        let parts = configValue
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyName = parts.last else { return nil }

        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "ctrl": modifiers.insert(.control)
            case "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard let keyCode = Self.keyCode(forName: keyName) else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    public var configValue: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(Self.name(forKeyCode: keyCode) ?? "?")
        return parts.joined(separator: "+")
    }

    /// Menu-bar style: glyphs in the platform's ⌃⌥⇧⌘ order, then the key.
    public var displayName: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        out += (Self.name(forKeyCode: keyCode) ?? "?").uppercased()
        return out
    }

    // MARK: - Key table

    /// US ANSI virtual keycodes for every key the recorder accepts. Letters,
    /// digits, function keys and unshifted punctuation -- keys whose meaning
    /// survives the trip through a config file. Return, Tab, Delete and
    /// arrows are deliberately absent: stealing those system-wide breaks
    /// typing everywhere.
    private static let namesByKeyCode: [UInt16: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
        34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o",
        35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v",
        13: "w", 7: "x", 16: "y", 6: "z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        49: "space", 50: "`", 27: "-", 24: "=", 33: "[", 30: "]",
        42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17",
        79: "f18", 80: "f19",
    ]

    private static let keyCodesByName: [String: UInt16] =
        Dictionary(uniqueKeysWithValues: namesByKeyCode.map { ($1, $0) })

    public static func name(forKeyCode keyCode: UInt16) -> String? {
        namesByKeyCode[keyCode]
    }

    public static func keyCode(forName name: String) -> UInt16? {
        keyCodesByName[name.lowercased()]
    }

    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        guard let name = namesByKeyCode[keyCode] else { return false }
        return name.count >= 2 && name.hasPrefix("f") && name.dropFirst().allSatisfy(\.isNumber)
    }
}
