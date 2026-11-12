import Testing
@testable import HintCore

struct TriggerValidationTests {
    @Test func aChordNeedsCommandControlOrOption() {
        #expect(HotKey.validated(keyCode: 38, modifiers: []) == .failure(.needsModifier))
        #expect(HotKey.validated(keyCode: 38, modifiers: [.shift]) == .failure(.needsModifier))
        #expect(HotKey.validated(keyCode: 38, modifiers: [.option]) == .success(HotKey(keyCode: 38, modifiers: [.option])))
        #expect(HotKey.validated(keyCode: VirtualKey.space, modifiers: [.command, .shift]) == .success(.commandShiftSpace))
    }

    @Test func escapeAndDeleteAreReserved() {
        #expect(HotKey.validated(keyCode: VirtualKey.escape, modifiers: [.command]) == .failure(.reservedKey))
        #expect(HotKey.validated(keyCode: VirtualKey.delete, modifiers: [.control, .option]) == .failure(.reservedKey))
    }

    @Test func everyValidTriggerPassesThroughRoutingAndNoTypedKeyDoes() throws {
        let trigger = try HotKey.validated(keyCode: 38, modifiers: [.control, .option, .command]).get()
        func route(_ code: UInt16, _ mods: Modifiers, _ c: Character?) -> TapVerdict {
            KeyRouting.route(keyCode: code, modifiers: mods, isRepeat: false, character: c, trigger: trigger, alphabet: .homeRow)
        }
        #expect(route(38, [.control, .option, .command], "j") == .passThrough)
        #expect(route(38, [], "j") == .swallow(.letter("j")))
        #expect(route(VirtualKey.escape, [], nil) == .swallow(.escape))
        #expect(route(VirtualKey.delete, [], nil) == .swallow(.backspace))
    }
}

struct KeyNameTests {
    @Test func keysWithoutACharacterHaveNames() {
        #expect(VirtualKey.name(for: VirtualKey.space) == "Space")
        #expect(VirtualKey.name(for: 36) == "↩")
        #expect(VirtualKey.name(for: 122) == "F1")
        #expect(VirtualKey.name(for: 90) == "F20")
        #expect(VirtualKey.name(for: 126) == "↑")
        #expect(VirtualKey.name(for: 38) == nil, "a letter key is named by the layout")
    }

    @Test func displayNameComposesModifiersAndKeyName() {
        let chord = HotKey(keyCode: 38, modifiers: [.command, .option, .control])
        #expect(chord.displayName(keyName: "J") == "⌃⌥⌘J")
        #expect(chord.displayName == "⌃⌥⌘key 38")
        #expect(HotKey(keyCode: 122, modifiers: [.control]).displayName == "⌃F1")
    }
}

struct UserSettingsTests {
    private let custom = UserSettings(trigger: HotKey(keyCode: 38, modifiers: [.control, .option, .command]))

    private func stored(_ code: Int?, _ mods: Int?) -> StoredSettings {
        StoredSettings(triggerKeyCode: code, triggerModifiers: mods)
    }

    @Test func standardMatchesTheStandardConfig() {
        #expect(UserSettings.standard == UserSettings(trigger: HintConfig.standard.trigger))
    }

    @Test func storedFormRoundTrips() {
        #expect(UserSettings(stored: custom.stored) == custom)
        #expect(UserSettings(stored: UserSettings.standard.stored) == .standard)
        #expect(custom.stored == stored(38, 13))
    }

    @Test func nothingStoredMeansStandard() {
        #expect(UserSettings(stored: stored(nil, nil)) == .standard)
    }

    @Test func aBadTriggerFallsBackToStandard() {
        let cases: [(Int?, Int?)] = [
            (nil, 13), (38, nil), (-1, 13), (128, 13), (38, -1), (38, 16), (38, 256), (38, 0), (38, 2), (53, 1), (51, 1),
        ]
        for (code, mods) in cases {
            let parsed = UserSettings(stored: stored(code, mods))
            #expect(parsed.trigger == UserSettings.standard.trigger, "code \(String(describing: code)) mods \(String(describing: mods))")
        }
    }


    @Test func applyingReplacesOnlyTheUserSettings() {
        let config = HintConfig.standard.applying(custom)
        #expect(config.settings == custom)
        #expect(config.alphabet == HintConfig.standard.alphabet)
        #expect(config.scanBudget == HintConfig.standard.scanBudget)
        #expect(config.clickPolicy == HintConfig.standard.clickPolicy)
    }
}
