import Testing
@testable import HintCore

struct ShortcutStatusTests {
    private let chord = HotKey.commandShiftSpace
    private let other = HotKey(keyCode: 38, modifiers: [.control, .option, .command])

    private func status(_ registration: HotKeyRegistration, taken: Set<HotKey> = []) -> ShortcutStatus {
        ShortcutStatus(registration: registration, trigger: chord, macOSShortcuts: taken)
    }

    @Test func aRegisteredChordWorksAndHasNoProblem() {
        #expect(status(.registered) == .registered)
        #expect(status(.registered).works)
        #expect(status(.registered).problem(chord: "⇧⌘Space") == nil)
        #expect(status(.registered, taken: [other]) == .registered, "another chord's macOS shortcut does not matter")
    }

    @Test func aMacOSShortcutWinsOverWhateverCarbonAnswered() {
        #expect(status(.registered, taken: [chord]) == .takenByMacOS)
        #expect(status(.failed(-1), taken: [chord]) == .takenByMacOS)
        #expect(!status(.registered, taken: [chord]).works)
        #expect(status(.registered, taken: [chord]).problem(chord: "⇧⌘Space")?.contains("macOS shortcut") == true)
    }

    @Test func aFailedRegistrationDoesNotWorkAndSaysWhy() {
        let exists = status(.failed(ShortcutStatus.chordExistsError))
        #expect(exists == .notRegistered(-9878))
        #expect(!exists.works)
        #expect(exists.menuText == "not registered, the chord is already registered")
        #expect(exists.problem(chord: "⌃⌥⌘J") == "Another app already registered ⌃⌥⌘J. Pick another one.")
        let unknown = status(.failed(-50))
        #expect(unknown.menuText == "not registered (error -50)")
        #expect(unknown.problem(chord: "⌃⌥⌘J") == "macOS didn't accept ⌃⌥⌘J (error -50). Pick another one.")
    }
}

struct CarbonModifierTests {
    @Test func eachModifierHasItsCarbonMask() {
        #expect(Modifiers.command.carbonFlags == 256)
        #expect(Modifiers.shift.carbonFlags == 512)
        #expect(Modifiers.option.carbonFlags == 2048)
        #expect(Modifiers.control.carbonFlags == 4096)
        #expect(Modifiers([.command, .shift]).carbonFlags == 768)
    }

    @Test(arguments: 0...Modifiers.all.rawValue)
    func everyModifierSetRoundTripsThroughCarbon(raw: UInt8) {
        let modifiers = Modifiers(rawValue: raw)
        #expect(Modifiers(carbonFlags: modifiers.carbonFlags) == modifiers)
    }

    @Test func otherCarbonFlagsAreIgnored() {
        #expect(Modifiers(carbonFlags: 0x0400 | 0x0100) == .command, "0x0400 is alphaLock")
        #expect(Modifiers(carbonFlags: 0) == [])
    }
}
