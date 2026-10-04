import AppKit
import Carbon.HIToolbox

/// Escape as a way out of the effect.
///
/// The picture sits above the menu bar and lets clicks through, so a run that
/// does not end hides the panel that could stop it. A Carbon hot key needs no
/// Accessibility permission, unlike a global key monitor, but it takes the key
/// from every other app while registered. So it is armed only while a run's
/// picture covers the screen.
@MainActor
final class EscapeKey {

    /// Called on the main thread for a press while armed.
    var onPress: (() -> Void)?

    var isArmed = false {
        didSet {
            guard isArmed != oldValue else { return }
            if isArmed { register() } else { unregister() }
        }
    }

    // Reached from `deinit`, which is not isolated to the main actor.
    private nonisolated(unsafe) var hotKey: EventHotKeyRef?
    private nonisolated(unsafe) var handler: EventHandlerRef?

    deinit {
        // The handler holds an unretained pointer to this object.
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// One attempt per arming. A key another app already holds stays
    /// unavailable until the next run, rather than retried on every reading.
    private func register() {
        let target = GetApplicationEventTarget()
        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var status = InstallEventHandler(
            target,
            handleHotKey,
            1,
            &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        if status == noErr {
            status = RegisterEventHotKey(UInt32(kVK_Escape), 0, escapeHotKeyID, target, 0, &hotKey)
        }
        guard status != noErr else { return }
        Diagnostics.lid.error("escape key unavailable, status \(status)")
        unregister()
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    fileprivate func press() {
        // The run may have ended between the key and this turn of the loop.
        guard isArmed else { return }
        onPress?()
    }
}

/// 'MDuo', so the handler can tell this key from any other.
private let escapeHotKeyID = EventHotKeyID(signature: 0x4D44_756F, id: 1)

/// A C callback, so it reaches the instance through `userData`.
private func handleHotKey(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var pressed = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &pressed
    )
    guard status == noErr,
          pressed.signature == escapeHotKeyID.signature,
          pressed.id == escapeHotKeyID.id else { return OSStatus(eventNotHandledErr) }
    let key = Unmanaged<EscapeKey>.fromOpaque(userData).takeUnretainedValue()
    // Ending the run disarms the key, which removes this handler, so that
    // waits until the handler has returned.
    DispatchQueue.main.async {
        MainActor.assumeIsolated { key.press() }
    }
    return noErr
}
