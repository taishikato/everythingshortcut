/// The part of `HintConfig` the user edits in Settings.
public struct UserSettings: Hashable, Sendable {
    public var trigger: HotKey
    public var alphabet: Alphabet

    public init(trigger: HotKey, alphabet: Alphabet) {
        self.trigger = trigger
        self.alphabet = alphabet
    }

    public static let standard = HintConfig.standard.settings

    /// Parses what was persisted. Each field that is missing or invalid falls back to `standard` on its own,
    /// so a bad trigger never costs the user their alphabet.
    public init(stored: StoredSettings) {
        trigger = Self.trigger(stored) ?? Self.standard.trigger
        alphabet = stored.alphabet.flatMap { try? Alphabet.parse($0).get() } ?? Self.standard.alphabet
    }

    public var stored: StoredSettings {
        StoredSettings(
            triggerKeyCode: Int(trigger.keyCode),
            triggerModifiers: Int(trigger.modifiers.rawValue),
            alphabet: alphabet.string
        )
    }

    private static func trigger(_ stored: StoredSettings) -> HotKey? {
        guard let code = stored.triggerKeyCode, (0..<128).contains(code),
              let bits = stored.triggerModifiers, (0...Int(Modifiers.all.rawValue)).contains(bits)
        else { return nil }
        return try? HotKey.validated(keyCode: UInt16(code), modifiers: Modifiers(rawValue: UInt8(bits))).get()
    }
}

/// `UserSettings` as persisted, before parsing. Any field may be missing or hold a value no version wrote.
public struct StoredSettings: Hashable, Sendable {
    public var triggerKeyCode: Int?
    public var triggerModifiers: Int?
    public var alphabet: String?

    public init(triggerKeyCode: Int?, triggerModifiers: Int?, alphabet: String?) {
        self.triggerKeyCode = triggerKeyCode
        self.triggerModifiers = triggerModifiers
        self.alphabet = alphabet
    }
}

extension HintConfig {
    public func applying(_ settings: UserSettings) -> HintConfig {
        var config = self
        config.trigger = settings.trigger
        config.alphabet = settings.alphabet
        return config
    }

    public var settings: UserSettings { UserSettings(trigger: trigger, alphabet: alphabet) }
}
