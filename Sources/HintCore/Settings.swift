/// The part of `HintConfig` the user edits in Settings.
public struct UserSettings: Hashable, Sendable {
    public var trigger: HotKey

    public init(trigger: HotKey) {
        self.trigger = trigger
    }

    public static let standard = HintConfig.standard.settings

    /// Parses what was persisted. A missing or invalid trigger falls back to `standard`.
    public init(stored: StoredSettings) {
        trigger = Self.trigger(stored) ?? Self.standard.trigger
    }

    public var stored: StoredSettings {
        StoredSettings(triggerKeyCode: Int(trigger.keyCode), triggerModifiers: Int(trigger.modifiers.rawValue))
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

    public init(triggerKeyCode: Int?, triggerModifiers: Int?) {
        self.triggerKeyCode = triggerKeyCode
        self.triggerModifiers = triggerModifiers
    }
}

extension HintConfig {
    public func applying(_ settings: UserSettings) -> HintConfig {
        var config = self
        config.trigger = settings.trigger
        return config
    }

    public var settings: UserSettings { UserSettings(trigger: trigger) }
}
