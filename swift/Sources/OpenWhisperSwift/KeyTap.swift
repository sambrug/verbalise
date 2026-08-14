import CoreGraphics
import Foundation
import OpenWhisperCore

/// Listen-only `CGEventTap` over modifier changes.
///
/// Phase 1 scope: prove the tap installs and reports the trigger key exactly
/// under the sandbox. The Phase 4 `KeyMonitor` builds on this class rather than
/// replacing it -- the tap plumbing (creation, run loop source, re-enable on
/// disable) is the part that has to be right, and it is the same either way.
///
/// Two rules the Python comments (daemon.py:1761-1813) spend a long time on,
/// both preserved here:
///
///  * The tap is `.listenOnly`. We observe the trigger key, we never swallow
///    it -- the key must keep working normally in whatever app has focus.
///  * The callback thread does no slow work. macOS silently disables a tap
///    whose callback overruns, so the callback classifies the event and hands
///    off immediately; anything expensive happens elsewhere.
final class KeyTap: @unchecked Sendable {

    /// Called with `true` on press and `false` on release of the configured
    /// combo. Always delivered on the main actor, never on the tap thread.
    typealias Handler = @MainActor (Bool) -> Void

    private var combo: TriggerCombo
    private let onChange: Handler
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Last reported state, so we emit an edge only when it actually changes.
    /// A combo produces one flagsChanged event per key, and holding a key
    /// generates no repeats, but chording still yields several events that all
    /// evaluate to "held".
    private var isHeld = false

    init(combo: TriggerCombo, onChange: @escaping Handler) {
        self.combo = combo
        self.onChange = onChange
    }

    /// Installs the tap. Returns false when the OS refuses, which in practice
    /// means Input Monitoring has not been granted.
    @discardableResult
    func start() -> Bool {
        guard machPort == nil else { return true }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
                tap.handle(type: type, event: event)
                // Listen-only: the return value is ignored, but the callback
                // signature still requires the event be handed back.
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("key tap: tapCreate failed (Input Monitoring not granted?)")
            return false
        }

        machPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        log("key tap: installed for \(combo.configValue)")
        return true
    }

    func stop() {
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        machPort = nil
        runLoopSource = nil
        isHeld = false
    }

    /// Live config reload: swap the combo without tearing the tap down, so a
    /// trigger-key change never costs the user their Input Monitoring grant or
    /// leaves a window where the key does nothing.
    @MainActor
    func update(combo newCombo: TriggerCombo) {
        combo = newCombo
        isHeld = false
        log("key tap: trigger is now \(newCombo.configValue)")
    }

    // MARK: - Tap thread

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables a tap that overruns its callback budget, or when the
        // user does something the window server treats as input-stealing.
        // Re-enable rather than going silently deaf for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort {
                CGEvent.tapEnable(tap: machPort, enable: true)
            }
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
            log("key tap: re-enabled after disable-by-\(reason)")
            return
        }

        guard type == .flagsChanged else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard combo.involves(keyCode: keyCode) else { return }

        // Stateless and exact: the device-dependent bits say which *physical*
        // key is down, so left and right never get confused and a dropped
        // event cannot leave us out of sync.
        let held = combo.isFullyHeld(flags: event.flags.rawValue)
        guard held != isHeld else { return }
        isHeld = held

        let handler = onChange
        // Hop off the tap thread immediately -- everything downstream (audio
        // engine start, model wake, transcription) is far too slow to run here.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handler(held)
            }
        }
    }
}
