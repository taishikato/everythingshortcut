import Carbon
import HintCore

/// Key code to character through the current ASCII-capable keyboard layout.
/// Labels then type the same under Dvorak, or under a Japanese IME in kana mode, which reports the
/// underlying Latin layout as its ASCII-capable source. Text Input Sources are main-thread only.
/// The layout is looked up on every call, so a layout switch needs no notification handling.
@MainActor
final class KeyboardLayout {
    /// The unshifted character for `keyCode`, or nil for keys that produce none.
    func character(for keyCode: UInt16) -> Character? {
        withLayout { Self.translate(keyCode, in: $0) } ?? nil
    }

    /// The name a person reads for `keyCode`: the core's table for keys that type nothing printable,
    /// else the layout's character uppercased as on the keycap, else "key N".
    func keyName(for keyCode: UInt16) -> String {
        if let name = VirtualKey.name(for: keyCode) { return name }
        if let c = character(for: keyCode), !c.isWhitespace, !c.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return c.uppercased()
        }
        return "key \(keyCode)"
    }

    /// Every chord the UI shows goes through here, so the menu and Settings name it the same way.
    func name(of hotKey: HotKey) -> String {
        hotKey.displayName(keyName: keyName(for: hotKey.keyCode))
    }

    /// Inverse of `character(for:)` over key codes 0..<128. DEBUG automation uses it to post real keys.
    func keyCode(for character: Character) -> UInt16? {
        withLayout { layout in (0..<128).map(UInt16.init).first { Self.translate($0, in: layout) == character } } ?? nil
    }

    private func withLayout<T>(_ body: (UnsafePointer<UCKeyboardLayout>) -> T) -> T? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1, body)
    }

    private static func translate(_ keyCode: UInt16, in layout: UnsafePointer<UCKeyboardLayout>) -> Character? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(decoding: chars.prefix(length), as: UTF16.self).first
    }
}
