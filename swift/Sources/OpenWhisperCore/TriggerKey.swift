import CoreGraphics
import Foundation

/// The modifier keys that can be used as a trigger, matching the Python key set
/// (daemon.py:188). Config names are the wire format -- `trigger_key: shift_r`,
/// or a combo joined with `+` such as `alt_r+shift_r`.
///
/// Each case carries its virtual keycode *and* its device-dependent flag bit.
/// That second value is what fixes the limitation noted at daemon.py:199: a
/// `flagsChanged` event reports the plain `.maskShift` for either shift key, so
/// the plain mask cannot tell left from right. The device-dependent bits are
/// per-physical-key, so testing `flags & deviceMask` gives an exact, stateless
/// answer to "is this key currently held" -- no need to track down/up pairs and
/// no way to desync when the OS drops an event.
public enum TriggerKey: String, CaseIterable, Sendable, Codable {
    case shiftR = "shift_r"
    case shiftL = "shift_l"
    case ctrlR = "ctrl_r"
    case ctrlL = "ctrl_l"
    case altR = "alt_r"
    case altL = "alt_l"
    case cmdR = "cmd_r"

    /// Virtual keycode reported by `.keyboardEventKeycode` on a flagsChanged event.
    public var keyCode: Int64 {
        switch self {
        case .shiftL: 56
        case .shiftR: 60
        case .ctrlL: 59
        case .ctrlR: 62
        case .altL: 58
        case .altR: 61
        case .cmdR: 54
        }
    }

    /// Device-dependent modifier bit set while this specific physical key is held.
    /// These are the `NX_DEVICE*KEYMASK` values from IOKit's event headers.
    public var deviceMask: UInt64 {
        switch self {
        case .ctrlL: 0x0000_0001
        case .shiftL: 0x0000_0002
        case .shiftR: 0x0000_0004
        case .cmdR: 0x0000_0010
        case .altL: 0x0000_0020
        case .altR: 0x0000_0040
        case .ctrlR: 0x0000_2000
        }
    }

    /// Human-readable label for the menu's Trigger Key picker.
    public var displayName: String {
        switch self {
        case .shiftR: "Right Shift"
        case .shiftL: "Left Shift"
        case .ctrlR: "Right Control"
        case .ctrlL: "Left Control"
        case .altR: "Right Option"
        case .altL: "Left Option"
        case .cmdR: "Right Command"
        }
    }

    public static func from(keyCode: Int64) -> TriggerKey? {
        allCases.first { $0.keyCode == keyCode }
    }
}

/// One or more keys that must all be held. A single key is the common case;
/// `alt_r+shift_r` is the documented combo form.
public struct TriggerCombo: Equatable, Sendable {
    public let keys: [TriggerKey]

    public init(keys: [TriggerKey]) {
        self.keys = keys
    }

    /// Parses the config string. Returns nil on an unknown key name so the
    /// caller can surface a `configError` rather than silently falling back.
    public init?(configValue: String) {
        let parts = configValue
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var parsed: [TriggerKey] = []
        for part in parts {
            guard let key = TriggerKey(rawValue: part) else { return nil }
            parsed.append(key)
        }
        self.keys = parsed
    }

    public var configValue: String {
        keys.map(\.rawValue).joined(separator: "+")
    }

    public var displayName: String {
        keys.map(\.displayName).joined(separator: " + ")
    }

    /// True when every key in the combo is held, given a flagsChanged event's
    /// raw modifier flags.
    public func isFullyHeld(flags: UInt64) -> Bool {
        keys.allSatisfy { flags & $0.deviceMask != 0 }
    }

    /// True when this event concerns one of our keys at all -- used to ignore
    /// unrelated modifier traffic without doing any further work on the tap
    /// callback thread.
    public func involves(keyCode: Int64) -> Bool {
        keys.contains { $0.keyCode == keyCode }
    }
}
