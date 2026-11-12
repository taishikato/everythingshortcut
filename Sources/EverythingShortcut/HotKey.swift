import Carbon
import HintCore

/// The global trigger through Carbon `RegisterEventHotKey`. Needs no permission.
/// The single source of trigger presses: the event tap passes the chord through (`KeyRouting.route`).
/// One registration per process. `register` replaces the previous chord, so Settings changes the
/// trigger without a restart.
@MainActor
final class HotKeyCenter {
    typealias Registration = HotKeyRegistration

    var onPress: () -> Void = {}

    /// Reads the enabled macOS shortcuts. `ShortcutStatus` decides what they mean for the chord.
    static func status(_ registration: Registration, for hotKey: HotKey) -> ShortcutStatus {
        ShortcutStatus(registration: registration, trigger: hotKey, macOSShortcuts: SystemShortcuts.enabled())
    }
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(_ hotKey: HotKey) -> Registration {
        if handlerRef == nil {
            // The core hardcodes these Carbon values, because it imports nothing.
            assert(ShortcutStatus.chordExistsError == eventHotKeyExistsErr)
            assert(Modifiers.command.carbonFlags == UInt32(cmdKey) && Modifiers.shift.carbonFlags == UInt32(shiftKey))
            assert(Modifiers.option.carbonFlags == UInt32(optionKey) && Modifiers.control.carbonFlags == UInt32(controlKey))
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            guard status == noErr else { return .failed(status) }
        }
        unregister()
        let status = RegisterEventHotKey(
            UInt32(hotKey.keyCode),
            hotKey.modifiers.carbonFlags,
            EventHotKeyID(signature: 0x4576_5363, id: 1),   // 'EvSc'
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return status == noErr ? .registered : .failed(status)
    }

    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    fileprivate func fire() { onPress() }
}

/// Carbon dispatches hotkey events on the main thread, so the callback enters main-actor isolation directly.
private func hotKeyCallback(_ call: EventHandlerCallRef?, _ event: EventRef?, _ refcon: UnsafeMutableRawPointer?) -> OSStatus {
    guard let refcon else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { center.fire() }
    return noErr
}

/// The macOS shortcuts in System Settings > Keyboard > Keyboard Shortcuts that are turned on.
/// macOS handles these before any Carbon hotkey or key monitor, so a trigger among them never fires,
/// and the Settings recorder never sees them either (measured with ⌘Space and ⌥⌘Space).
enum SystemShortcuts {
    static func enabled() -> Set<HotKey> {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let entries = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(entries.compactMap { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int, (0..<128).contains(code),
                  let flags = entry[kHISymbolicHotKeyModifiers as String] as? Int
            else { return nil }
            return HotKey(keyCode: UInt16(code), modifiers: Modifiers(carbonFlags: UInt32(truncatingIfNeeded: flags)))
        })
    }
}
