import Carbon
import HintCore

/// The global trigger through Carbon `RegisterEventHotKey`. Needs no permission.
/// The single source of trigger presses: the event tap passes the chord through (`KeyRouting.route`).
/// One registration per process. `register` replaces the previous chord, so Settings changes the
/// trigger without a restart.
@MainActor
final class HotKeyCenter {
    enum Registration: Equatable, Sendable {
        case registered
        /// `eventHotKeyExistsErr` when the chord is already registered. A chord another process holds does not
        /// cause it, measured in docs/design.md, so `.registered` does not prove the chord reaches us.
        case failed(OSStatus)
    }

    var onPress: () -> Void = {}

    /// What the menu and Settings say about the trigger, in lowercase so either can lead with it.
    static func status(_ registration: Registration, for hotKey: HotKey) -> String {
        if SystemShortcuts.enabled().contains(hotKey) { return "not usable, a macOS shortcut takes it first" }
        return switch registration {
        case .registered: "registered"
        case .failed(let status) where status == eventHotKeyExistsErr: "not registered, the chord is already registered"
        case .failed(let status): "not registered (error \(status))"
        }
    }
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(_ hotKey: HotKey) -> Registration {
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            guard status == noErr else { return .failed(status) }
        }
        unregister()
        let status = RegisterEventHotKey(
            UInt32(hotKey.keyCode),
            Self.carbonModifiers(hotKey.modifiers),
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

    static func carbonModifiers(_ m: Modifiers) -> UInt32 {
        var flags = 0
        if m.contains(.command) { flags |= cmdKey }
        if m.contains(.shift) { flags |= shiftKey }
        if m.contains(.option) { flags |= optionKey }
        if m.contains(.control) { flags |= controlKey }
        return UInt32(flags)
    }
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
            return HotKey(keyCode: UInt16(code), modifiers: Modifiers(carbon: UInt32(truncatingIfNeeded: flags)))
        })
    }
}

extension Modifiers {
    /// The inverse of `HotKeyCenter.carbonModifiers`, ignoring every other Carbon flag.
    init(carbon flags: UInt32) {
        var m: Modifiers = []
        if flags & UInt32(cmdKey) != 0 { m.insert(.command) }
        if flags & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if flags & UInt32(optionKey) != 0 { m.insert(.option) }
        if flags & UInt32(controlKey) != 0 { m.insert(.control) }
        self = m
    }
}
