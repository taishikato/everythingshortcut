/// Whether Carbon accepted the trigger chord.
public enum HotKeyRegistration: Hashable, Sendable {
    case registered
    /// The `OSStatus` of the failed call. `ShortcutStatus.chordExistsError` when the chord is already
    /// registered. A chord another process holds does not cause it (measured), so `.registered` does not
    /// prove the chord reaches us.
    case failed(Int32)
}

/// The applied trigger as the user should hear about it. The status menu and the app window switch over
/// the same cases.
public enum ShortcutStatus: Hashable, Sendable {
    case registered
    /// An enabled macOS shortcut takes the chord first, so it never reaches us.
    case takenByMacOS
    case notRegistered(Int32)

    /// Carbon's `eventHotKeyExistsErr`. Hardcoded because the core does not import Carbon.
    /// `HotKeyCenter` asserts it against Carbon in DEBUG.
    public static let chordExistsError: Int32 = -9878

    /// macOS handles its own enabled shortcuts before any Carbon hotkey, so a chord among
    /// `macOSShortcuts` is taken whatever Carbon answered.
    public init(registration: HotKeyRegistration, trigger: HotKey, macOSShortcuts: Set<HotKey>) {
        if macOSShortcuts.contains(trigger) {
            self = .takenByMacOS
            return
        }
        switch registration {
        case .registered: self = .registered
        case .failed(let status): self = .notRegistered(status)
        }
    }

    /// A chord another app holds exclusively still reads `.registered`.
    public var works: Bool { self == .registered }

    /// After "Shortcut ⇧⌘Space: " in the status menu.
    public var menuText: String {
        switch self {
        case .registered: "registered"
        case .takenByMacOS: "taken by a macOS shortcut"
        case .notRegistered(Self.chordExistsError): "not registered, the chord is already registered"
        case .notRegistered(let status): "not registered (error \(status))"
        }
    }

    /// The orange line under the shortcut in the app window. Nil when it works.
    public func problem(chord: String) -> String? {
        switch self {
        case .registered: nil
        case .takenByMacOS: "A macOS shortcut already uses \(chord), so it never reaches the app. Pick another one."
        case .notRegistered(Self.chordExistsError): "Another app already registered \(chord). Pick another one."
        case .notRegistered(let status): "macOS didn't accept \(chord) (error \(status)). Pick another one."
        }
    }
}

extension Modifiers {
    /// Carbon's modifier masks (`cmdKey`, `shiftKey`, `optionKey`, `controlKey` in Events.h).
    /// Hardcoded because the core does not import Carbon. `HotKeyCenter` asserts them against Carbon in DEBUG.
    private static let carbonMasks: [(Modifiers, UInt32)] = [
        (.command, 0x0100), (.shift, 0x0200), (.option, 0x0800), (.control, 0x1000),
    ]

    /// The modifier flags `RegisterEventHotKey` takes.
    public var carbonFlags: UInt32 {
        Self.carbonMasks.reduce(0) { contains($1.0) ? $0 | $1.1 : $0 }
    }

    /// The inverse of `carbonFlags`, ignoring every other Carbon flag.
    public init(carbonFlags flags: UInt32) {
        self = Self.carbonMasks.reduce([]) { flags & $1.1 != 0 ? $0.union($1.0) : $0 }
    }
}
