#if APPSTORE
import Carbon.HIToolbox
import Foundation
import VerbaliseCore

/// The App Store build's trigger: a registered system hotkey.
///
/// `RegisterEventHotKey` is the sanctioned global-shortcut mechanism -- macOS
/// itself watches the keyboard and delivers only this combo's press and
/// release, so the app observes nothing else and no permission is involved.
/// That is the entire point: App Review rejected the Input Monitoring
/// permission the direct build's event tap needs (guideline 2.4.5(v)), and
/// this is the replacement that leaves nothing to object to.
///
/// Two behavioural differences from `KeyTap`, both inherent:
///
///  * The combo is swallowed system-wide. A registered hotkey never reaches
///    the focused app, which is why the default avoids anything apps use.
///  * Escape-cancel can't be a passive observer any more. Escape is
///    registered as a second hotkey only while the combo is held, so during
///    a dictation it cancels, and the rest of the time it belongs to the
///    focused app untouched.
///
/// Mirrors KeyTap's interface (press/release edges on the main actor, live
/// combo reload) so AppDelegate treats the two triggers identically.
final class HotKey {

    typealias Handler = @MainActor (Bool) -> Void

    private let onChange: Handler
    private let onEscape: @MainActor () -> Void
    private var combo: HotKeyCombo

    private var comboRef: EventHotKeyRef?
    private var escapeRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Deduplicates repeats: holding some keys makes Carbon deliver extra
    /// pressed events, and the state machine downstream wants edges only.
    private var isHeld = false

    private static let signature: OSType = 0x5642_4C53 // "VBLS"
    private static let comboID: UInt32 = 1
    private static let escapeID: UInt32 = 2
    private static let escapeKeyCode: UInt32 = 53

    init(
        combo: HotKeyCombo,
        onChange: @escaping Handler,
        onEscape: @escaping @MainActor () -> Void = {}
    ) {
        self.combo = combo
        self.onChange = onChange
        self.onEscape = onEscape
    }

    /// Installs the event handler and registers the combo. Returns false when
    /// registration is refused, which in practice means another app already
    /// owns this exact combo as its own registered hotkey.
    @MainActor
    @discardableResult
    func start() -> Bool {
        guard handlerRef == nil else { return true }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let installed = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, refcon in
                guard let event, let refcon else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                let kind = GetEventKind(event)
                let hotKey = Unmanaged<HotKey>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated {
                    hotKey.handle(id: hotKeyID.id, pressed: kind == UInt32(kEventHotKeyPressed))
                }
                return noErr
            },
            eventTypes.count, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard installed == noErr else {
            log("hotkey: event handler install failed (\(installed))")
            return false
        }

        guard registerCombo() else {
            stop()
            return false
        }
        log("hotkey: registered \(combo.configValue)")
        return true
    }

    @MainActor
    func stop() {
        setEscapeRegistered(false)
        if let comboRef { UnregisterEventHotKey(comboRef) }
        comboRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        isHeld = false
    }

    /// Live config reload, mirroring KeyTap: swap the combo without tearing
    /// down the handler, so a shortcut change never leaves a gap where the
    /// trigger does nothing.
    @MainActor
    func update(combo newCombo: HotKeyCombo) {
        guard newCombo != combo else { return }
        if let comboRef { UnregisterEventHotKey(comboRef) }
        comboRef = nil
        combo = newCombo
        isHeld = false
        setEscapeRegistered(false)
        if registerCombo() {
            log("hotkey: trigger is now \(newCombo.configValue)")
        } else {
            log("hotkey: could not register \(newCombo.configValue) -- taken by another app?")
        }
    }

    @MainActor
    private func registerCombo() -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode), combo.modifiers.rawValue,
            EventHotKeyID(signature: Self.signature, id: Self.comboID),
            GetEventDispatcherTarget(), 0, &ref
        )
        guard status == noErr, ref != nil else {
            log("hotkey: RegisterEventHotKey failed (\(status)) for \(combo.configValue)")
            return false
        }
        comboRef = ref
        return true
    }

    /// Escape exists as a hotkey only while the trigger is held: pressing it
    /// then cancels the dictation. Registered any longer than that, it would
    /// steal Escape from every app all the time.
    @MainActor
    private func setEscapeRegistered(_ wanted: Bool) {
        if wanted, escapeRef == nil {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                Self.escapeKeyCode, 0,
                EventHotKeyID(signature: Self.signature, id: Self.escapeID),
                GetEventDispatcherTarget(), 0, &ref
            )
            if status == noErr { escapeRef = ref }
        } else if !wanted, let ref = escapeRef {
            UnregisterEventHotKey(ref)
            escapeRef = nil
        }
    }

    @MainActor
    private func handle(id: UInt32, pressed: Bool) {
        switch id {
        case Self.comboID:
            guard pressed != isHeld else { return }
            isHeld = pressed
            setEscapeRegistered(pressed)
            onChange(pressed)
        case Self.escapeID:
            guard pressed else { return }
            onEscape()
        default:
            break
        }
    }
}
#endif
