import Testing
@testable import HintCore

struct AlphabetParseTests {
    @Test func uppercaseInputIsAcceptedAsLowercase() throws {
        #expect(try Alphabet.parse("ASDF").get().string == "asdf")
    }

    @Test func eachRejectionNamesItsReason() {
        #expect(Alphabet.parse("") == .failure(.tooShort))
        #expect(Alphabet.parse("a") == .failure(.tooShort))
        #expect(Alphabet.parse("a1") == .failure(.notALetter("1")))
        #expect(Alphabet.parse("a b") == .failure(.notALetter(" ")))
        #expect(Alphabet.parse("aé") == .failure(.notALetter("é")))
        #expect(Alphabet.parse("abA") == .failure(.repeated("a")))
    }

    @Test func messagesAreShortSentences() {
        #expect(AlphabetError.tooShort.message == "Use at least two letters.")
        #expect(AlphabetError.notALetter("1").message == "'1' is not a letter a-z.")
        #expect(AlphabetError.repeated("a").message == "'a' appears twice.")
    }

    @Test func strictInitializerStillRejectsUppercase() {
        #expect(Alphabet("aB") == nil)
        #expect(Alphabet("ab")?.string == "ab")
    }
}

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
            KeyRouting.route(keyCode: code, modifiers: mods, character: c, trigger: trigger, alphabet: .homeRow)
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
    private let custom = UserSettings(trigger: HotKey(keyCode: 38, modifiers: [.control, .option, .command]), alphabet: Alphabet("qwertyuiop")!)

    private func stored(_ code: Int?, _ mods: Int?, _ alphabet: String?) -> StoredSettings {
        StoredSettings(triggerKeyCode: code, triggerModifiers: mods, alphabet: alphabet)
    }

    @Test func standardMatchesTheStandardConfig() {
        #expect(UserSettings.standard == UserSettings(trigger: HintConfig.standard.trigger, alphabet: HintConfig.standard.alphabet))
    }

    @Test func storedFormRoundTrips() {
        #expect(UserSettings(stored: custom.stored) == custom)
        #expect(UserSettings(stored: UserSettings.standard.stored) == .standard)
        #expect(custom.stored == stored(38, 13, "qwertyuiop"))
    }

    @Test func nothingStoredMeansStandard() {
        #expect(UserSettings(stored: stored(nil, nil, nil)) == .standard)
    }

    @Test func aBadTriggerFallsBackAloneAndKeepsTheAlphabet() {
        let cases: [(Int?, Int?)] = [
            (nil, 13), (38, nil), (-1, 13), (128, 13), (38, -1), (38, 16), (38, 256), (38, 0), (38, 2), (53, 1), (51, 1),
        ]
        for (code, mods) in cases {
            let parsed = UserSettings(stored: stored(code, mods, "qwertyuiop"))
            #expect(parsed.trigger == UserSettings.standard.trigger, "code \(String(describing: code)) mods \(String(describing: mods))")
            #expect(parsed.alphabet == custom.alphabet)
        }
    }

    @Test func aBadAlphabetFallsBackAloneAndKeepsTheTrigger() {
        for alphabet in ["", "q", "qq", "q1"] {
            let parsed = UserSettings(stored: stored(38, 13, alphabet))
            #expect(parsed.alphabet == UserSettings.standard.alphabet, "alphabet '\(alphabet)'")
            #expect(parsed.trigger == custom.trigger)
        }
        #expect(UserSettings(stored: stored(38, 13, "QWE")).alphabet.string == "qwe")
    }

    @Test func applyingReplacesOnlyTheUserSettings() {
        let config = HintConfig.standard.applying(custom)
        #expect(config.settings == custom)
        #expect(config.scanBudget == HintConfig.standard.scanBudget)
        #expect(config.clickPolicy == HintConfig.standard.clickPolicy)
    }
}
