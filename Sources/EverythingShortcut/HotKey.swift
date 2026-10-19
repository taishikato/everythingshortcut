import Carbon
import HintCore

/// The global trigger through Carbon `RegisterEventHotKey`. Needs no permission.
/// The single source of trigger presses: the event tap passes the chord through (`KeyRouting.route`).
/// One registration per process. `register` replaces the previous chord, so a settings screen can
/// change the trigger without restarting.
@MainActor
final class HotKeyCenter {
    enum Registration: Equatable, Sendable {
        case registered
        /// `eventHotKeyExistsErr` when another app already holds the chord.
        case failed(OSStatus)
    }

    var onPress: () -> Void = {}
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(_ hotKey: HotKey) -> Registration {
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            guard status == noErr else { return .failed(status) }
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
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
