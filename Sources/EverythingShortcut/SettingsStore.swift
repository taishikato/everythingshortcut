import Foundation
import HintCore

/// `UserSettings` in `UserDefaults.standard`. Reads go through `StoredSettings`, so a value of the wrong
/// type or out of range falls back per field instead of reaching the app.
enum SettingsStore {
    private static let triggerKeyCode = "triggerKeyCode"
    private static let triggerModifiers = "triggerModifiers"
    private static let alphabet = "labelAlphabet"

    static func load() -> UserSettings {
        let defaults = UserDefaults.standard
        return UserSettings(stored: StoredSettings(
            triggerKeyCode: defaults.object(forKey: triggerKeyCode) as? Int,
            triggerModifiers: defaults.object(forKey: triggerModifiers) as? Int,
            alphabet: defaults.object(forKey: alphabet) as? String
        ))
    }

    static func save(_ settings: UserSettings) {
        let defaults = UserDefaults.standard
        let stored = settings.stored
        defaults.set(stored.triggerKeyCode, forKey: triggerKeyCode)
        defaults.set(stored.triggerModifiers, forKey: triggerModifiers)
        defaults.set(stored.alphabet, forKey: alphabet)
    }
}
