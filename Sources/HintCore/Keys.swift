/// Modifier keys, independent of Carbon and CGEventFlags.
/// The shell converts at its two boundaries (Carbon hotkey registration, event tap flags).
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)
}

/// macOS virtual key codes (kVK_* in Carbon's Events.h) that the core needs by name.
public enum VirtualKey {
    public static let space: UInt16 = 49
    public static let escape: UInt16 = 53
    public static let delete: UInt16 = 51
}

/// A global trigger chord. Physical key code plus exact modifier set.
public struct HotKey: Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Homerow's and Shortcat's default.
    public static let commandShiftSpace = HotKey(keyCode: VirtualKey.space, modifiers: [.command, .shift])
}

/// What a key press means to the hint session. Everything else is swallowed and dropped.
public enum KeyInput: Hashable, Sendable {
    case letter(Character)
    case backspace
    case escape
}

/// The event tap's decision for one keyDown while hint mode is active.
public enum TapVerdict: Hashable, Sendable {
    /// Let the event continue to the system.
    case passThrough
    /// Consume the event. The frontmost app never sees it. Forward the input if non-nil.
    case swallow(KeyInput?)
}

public enum KeyRouting {
    /// Classifies one keyDown seen by the active event tap.
    ///
    /// The trigger chord passes through untouched. Carbon's hotkey is the single source of
    /// trigger presses, whichever order macOS runs hotkey matching and session taps in.
    /// If Carbon matches first, the tap never sees the chord. If the tap runs first, passing it on
    /// lets Carbon consume it. Either way one physical press yields exactly one `.trigger` event.
    ///
    /// Every other key is swallowed so typing labels never reaches the frontmost app.
    /// Command, Control and Option chords are swallowed and dropped, so Cmd-W cannot close
    /// a window mid-session. Shift is ignored so uppercase typing matches uppercase badges.
    ///
    /// `character` is the key's character in the ASCII-capable keyboard layout, so a Japanese IME
    /// in kana mode still yields Latin letters. This function lowercases it.
    public static func route(
        keyCode: UInt16,
        modifiers: Modifiers,
        character: Character?,
        trigger: HotKey,
        alphabet: Alphabet
    ) -> TapVerdict {
        if keyCode == trigger.keyCode && modifiers == trigger.modifiers { return .passThrough }
        if keyCode == VirtualKey.escape { return .swallow(.escape) }
        if !modifiers.isDisjoint(with: [.command, .control, .option]) { return .swallow(nil) }
        if keyCode == VirtualKey.delete { return .swallow(.backspace) }
        guard let c = character.flatMap({ $0.lowercased().first }), alphabet.contains(c) else {
            return .swallow(nil)
        }
        return .swallow(.letter(c))
    }
}
