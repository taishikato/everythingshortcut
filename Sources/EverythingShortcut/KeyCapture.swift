import CoreGraphics
import HintCore

/// The event tap that owns typing while hint mode is active, and sees every mouse-down.
///
/// Lifecycle. Created on the first activation (it needs Accessibility), then kept for the life of the
/// process and toggled with `CGEvent.tapEnable`. A disabled tap costs nothing and sees nothing.
/// Session level, head insert, keyDown plus left, right and other mouse-down. Orphan keyUps after
/// deactivation reach the frontmost app and are harmless.
///
/// Threading. The run-loop source is on the main run loop, so the C callback runs on the main thread and
/// enters main-actor isolation with `assumeIsolated`. The callback must return fast or macOS disables the
/// tap with `tapDisabledByTimeout`. It only classifies and forwards. Rendering happens in the same turn,
/// and scanning and performing are async.
@MainActor
final class KeyCapture {
    var onKey: (KeyInput) -> Void = { _ in }
    var onMouseDown: () -> Void = {}
    var onLost: () -> Void = {}
    private let trigger: HotKey
    private let alphabet: Alphabet
    private let layout = KeyboardLayout()
    private var port: CFMachPort?
    private var isActive = false

    init(trigger: HotKey, alphabet: Alphabet) {
        self.trigger = trigger
        self.alphabet = alphabet
    }

    /// Idempotent. Returns false when the tap cannot be created or enabled (not trusted).
    func setActive(_ active: Bool) -> Bool {
        guard active != isActive else { return true }
        if active, port == nil {
            let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue },
                callback: keyCaptureCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
            guard let port else { return false }
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        }
        guard let port else { return !active }
        CGEvent.tapEnable(tap: port, enable: active)
        isActive = active
        return !active || CGEvent.tapIsEnabled(tap: port)
    }

    /// Returns true to swallow the event.
    fileprivate func handle(_ event: TapEvent) -> Bool {
        switch event {
        case .tapDisabled:
            guard isActive, let port else { return false }
            CGEvent.tapEnable(tap: port, enable: true)
            if !CGEvent.tapIsEnabled(tap: port) {
                isActive = false
                onLost()
            }
            return false
        case .mouseDown where isActive:
            onMouseDown()
            return false
        case .keyDown(let keyCode, let modifiers) where isActive:
            let verdict = KeyRouting.route(
                keyCode: keyCode,
                modifiers: modifiers,
                character: layout.character(for: keyCode),
                trigger: trigger,
                alphabet: alphabet
            )
            switch verdict {
            case .passThrough:
                return false
            case .swallow(let input):
                if let input { onKey(input) }
                return true
            }
        default:
            // An event racing a disable passes through.
            return false
        }
    }
}

/// The Sendable facts of one tapped event. The CGEvent itself never crosses into the isolated closure.
private enum TapEvent: Sendable {
    case keyDown(keyCode: UInt16, modifiers: Modifiers)
    case mouseDown
    case tapDisabled
    case other
}

extension Modifiers {
    init(_ flags: CGEventFlags) {
        var m: Modifiers = []
        if flags.contains(.maskCommand) { m.insert(.command) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskControl) { m.insert(.control) }
        self = m
    }
}

/// Classifies by type before reading any field, because the key code field is meaningless on mouse events.
private func keyCaptureCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<KeyCapture>.fromOpaque(refcon).takeUnretainedValue()
    let tapped: TapEvent = switch type {
    case .keyDown:
        .keyDown(keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)), modifiers: Modifiers(event.flags))
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        .mouseDown
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        .tapDisabled
    default:
        .other
    }
    let swallow = MainActor.assumeIsolated { capture.handle(tapped) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
