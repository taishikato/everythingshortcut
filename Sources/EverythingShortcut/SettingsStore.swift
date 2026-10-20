import Foundation
import HintCore

/// `UserSettings` and the setup flags in `UserDefaults.standard`. Settings reads go through `StoredSettings`,
/// so a value of the wrong type or out of range falls back per field instead of reaching the app.
enum SettingsStore {
    private static let triggerKeyCode = "triggerKeyCode"
    private static let triggerModifiers = "triggerModifiers"

    static func load() -> UserSettings {
        let defaults = UserDefaults.standard
        return UserSettings(stored: StoredSettings(
            triggerKeyCode: defaults.object(forKey: triggerKeyCode) as? Int,
            triggerModifiers: defaults.object(forKey: triggerModifiers) as? Int
        ))
    }

    static func save(_ settings: UserSettings) {
        let defaults = UserDefaults.standard
        let stored = settings.stored
        defaults.set(stored.triggerKeyCode, forKey: triggerKeyCode)
        defaults.set(stored.triggerModifiers, forKey: triggerModifiers)
    }

    /// Setup was finished or skipped once. A missing or non-Bool value reads false, so setup shows again.
    static var setupComplete: Bool {
        get { UserDefaults.standard.object(forKey: "setupComplete") as? Bool == true }
        set { UserDefaults.standard.set(newValue, forKey: "setupComplete") }
    }

    /// The system Accessibility prompt has been requested once. macOS shows it only while it has no entry
    /// for the app, so later requests open the pane as well.
    static var accessibilityPrompted: Bool {
        get { UserDefaults.standard.object(forKey: "accessibilityPrompted") as? Bool == true }
        set { UserDefaults.standard.set(newValue, forKey: "accessibilityPrompted") }
    }
}
