import Testing
@testable import HintCore

private let other = HotKey(keyCode: 38, modifiers: [.control, .option, .command])   // ⌃⌥⌘J

private func facts(trusted: Bool = true, works: Bool = true, trigger: HotKey = .commandShiftSpace) -> SetupFacts {
    SetupFacts(trusted: trusted, shortcutWorks: works, trigger: trigger)
}

private func firstRun(trusted: Bool = true, works: Bool = true) -> SetupGuide {
    SetupGuide(facts: facts(trusted: trusted, works: works), isComplete: false)
}

private func labelsOpen() -> SetupGuide {
    var g = firstRun()
    _ = g.send(.session(.started))
    return g
}

struct SetupGuideTests {
    @Test func firstRunWithoutAccessStartsAtAccessAndLocksThePractice() {
        let g = firstRun(trusted: false)
        #expect(g.current == .access)
        #expect(g.isDone(.shortcut), "a working default shortcut is already checked")
        #expect(g.practiceRow == .locked)
        #expect(g.returnAction == .openSystemSettings)
    }

    @Test func grantingAccessComesForwardOnceAndMovesToThePractice() {
        var g = firstRun(trusted: false)
        #expect(g.send(.refreshed(facts(trusted: true))) == [.comeForward])
        #expect(g.current == .practice)
        #expect(g.practiceRow == .open(.ready))
        #expect(g.returnAction == nil, "the practice is done with the trigger, not with Return")
        #expect(g.send(.refreshed(facts(trusted: true))) == [], "no second come-forward while nothing changed")
    }

    @Test func losingAccessDoesNotComeForward() {
        var g = firstRun()
        #expect(g.send(.refreshed(facts(trusted: false))) == [])
        #expect(g.current == .access)
        #expect(g.practiceRow == .locked)
    }

    @Test func aShortcutMacOSTakesIsCurrentBeforeThePractice() {
        let g = firstRun(works: false)
        #expect(g.current == .shortcut)
        #expect(g.practiceRow == .locked)
        #expect(g.returnAction == .recordShortcut)
    }

    @Test func askingForAccessSwitchesToTheWaitingCopyUntilDismissed() {
        var g = firstRun(trusted: false)
        #expect(!g.accessAsked)
        #expect(g.send(.askedForAccess) == [])
        #expect(g.accessAsked)
        _ = g.send(.dismissed)
        #expect(!g.accessAsked)
    }

    @Test func theTargetsLabelSucceedsAndTheEndOfThatSessionKeepsIt() {
        var g = labelsOpen()
        #expect(g.send(.targetPressed(viaLabel: true)) == [])
        #expect(g.practice == .succeeded)
        #expect(g.send(.session(.ended(performed: true))) == [])
        #expect(g.practice == .succeeded)
        #expect(g.current == nil)
        #expect(g.returnAction == .finish)
    }

    @Test func aLabelThatClickedSomethingElseIsAMiss() {
        var g = labelsOpen()
        _ = g.send(.session(.ended(performed: true)))
        #expect(g.practice == .missed(.elsewhere))
        #expect(g.practiceRow == .open(.missed(.elsewhere)))
    }

    @Test func closingTheLabelsIsAMissAndTheNextTriggerRetries() {
        var g = labelsOpen()
        _ = g.send(.session(.ended(performed: false)))
        #expect(g.practice == .missed(.closed))
        _ = g.send(.session(.started))
        #expect(g.practice == .labelsOpen)
    }

    @Test func pressingTheTargetWithoutALabelIsNotSuccess() {
        var g = firstRun()
        _ = g.send(.targetPressed(viaLabel: false))
        #expect(g.practice == .missed(.withoutLabel))
        var clicked = labelsOpen()
        _ = clicked.send(.session(.ended(performed: false)))   // the mouse-down closes the labels first
        _ = clicked.send(.targetPressed(viaLabel: false))
        #expect(clicked.practice == .missed(.withoutLabel))
    }

    @Test func aLabelAfterAMissStillSucceeds() {
        var g = firstRun()
        _ = g.send(.targetPressed(viaLabel: false))
        _ = g.send(.session(.started))
        _ = g.send(.targetPressed(viaLabel: true))
        #expect(g.practice == .succeeded)
    }

    @Test func secureInputBlocksAndTheNextTriggerRecovers() {
        var g = firstRun()
        _ = g.send(.session(.blocked(.secureInputActive)))
        #expect(g.practice == .secureInput)
        _ = g.send(.session(.started))
        #expect(g.practice == .labelsOpen)
    }

    @Test func aBlockedTriggerForAccessibilityLeavesThePracticeAlone() {
        var g = firstRun()
        #expect(g.send(.session(.blocked(.needsAccessibility))) == [])
        #expect(g.practice == .ready)
    }

    @Test func aSessionThatBeganBeforeThePracticeDoesNotCountAsAMiss() {
        var g = SetupGuide(facts: facts(), isComplete: true)
        _ = g.send(.tryAgain)
        _ = g.send(.session(.ended(performed: true)))
        #expect(g.practice == .ready)
    }

    @Test func sessionsAreIgnoredWhileNobodyAskedForThePractice() {
        var g = SetupGuide(facts: facts(), isComplete: true)
        #expect(g.practiceRow == nil)
        for note in [SessionNote.started, .ended(performed: true), .blocked(.secureInputActive)] {
            #expect(g.send(.session(note)) == [])
        }
        _ = g.send(.targetPressed(viaLabel: true))
        #expect(g.practice == .idle)
        #expect(g.current == nil)
    }

    @Test func tryAgainOpensThePracticeAfterSetupIsComplete() {
        var g = SetupGuide(facts: facts(), isComplete: true)
        _ = g.send(.tryAgain)
        #expect(g.practiceRow == .open(.ready))
        #expect(g.current == .practice)
        _ = g.send(.session(.started))
        _ = g.send(.targetPressed(viaLabel: true))
        #expect(g.practice == .succeeded)
        #expect(g.returnAction == nil, "Done exists only during first-run setup")
    }

    @Test func aNewTriggerReopensThePracticeEvenAfterSuccess() {
        var g = labelsOpen()
        _ = g.send(.targetPressed(viaLabel: true))
        _ = g.send(.refreshed(facts(trigger: other)))
        #expect(g.practice == .ready)
        var settled = SetupGuide(facts: facts(), isComplete: true)
        _ = settled.send(.refreshed(facts(trigger: other)))
        #expect(settled.practice == .ready)
    }

    @Test func refreshingTheSameTriggerKeepsThePractice() {
        var g = labelsOpen()
        _ = g.send(.refreshed(facts()))
        #expect(g.practice == .labelsOpen, "Restore Defaults to the chord already in use changes nothing")
    }

    @Test func aSuccessStaysReadableWhenAccessIsLostAfterIt() {
        var g = labelsOpen()
        _ = g.send(.targetPressed(viaLabel: true))
        _ = g.send(.refreshed(facts(trusted: false)))
        #expect(g.practiceRow == .open(.succeeded))
        #expect(g.current == .access)
        #expect(g.returnAction == .openSystemSettings)
    }

    @Test func dismissingPersistsCompletionExactlyOnceAndHidesThePractice() {
        var g = firstRun(trusted: false)
        #expect(g.send(.dismissed) == [.persistComplete])
        #expect(g.isComplete)
        #expect(g.practiceRow == nil)
        #expect(g.current == .access, "Accessibility still needs the user")
        #expect(g.send(.dismissed) == [])
        var settled = SetupGuide(facts: facts(), isComplete: true)
        #expect(settled.send(.dismissed) == [], "a guide that started complete never stores it again")
    }

    @Test func theWindowOpensAtLaunchUntilSetupIsDoneThenOnlyWithoutAccessibility() {
        #expect(firstRun().opensAtLaunch)
        #expect(firstRun(trusted: false, works: false).opensAtLaunch)
        #expect(SetupGuide(facts: facts(trusted: false), isComplete: true).opensAtLaunch)
        #expect(!SetupGuide(facts: facts(works: false), isComplete: true).opensAtLaunch, "a login launch never nags about the shortcut")
        #expect(!SetupGuide(facts: facts(), isComplete: true).opensAtLaunch)
    }
}

struct SessionNoteTests {
    private func step(_ m: inout HintMachine<Int>, _ e: Event<Int>) -> SessionNote? {
        let before = m.phase
        _ = m.send(e)
        return SessionNote.of(e, from: before, to: m.phase)
    }

    private func candidates() -> [Candidate<Int>] {
        (0..<3).map { Candidate(target: $0, pid: PID(1), surface: .window(WindowID(1)), frame: GlobalRect(x: Double($0) * 30, y: 0, width: 20, height: 10)) }
    }

    @Test func aReadyTriggerStartsASession() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        #expect(step(&m, .trigger(.ready)) == .started)
    }

    @Test func aBlockedTriggerIsANoteAndStaysIdle() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        #expect(step(&m, .trigger(.blocked(.secureInputActive))) == .blocked(.secureInputActive))
        #expect(step(&m, .trigger(.blocked(.needsAccessibility))) == .blocked(.needsAccessibility))
    }

    @Test func aTypedLabelEndsWithAClickOnlyAfterThePerform() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        _ = step(&m, .trigger(.ready))
        #expect(step(&m, .scanned(ScanID(raw: 1), candidates())) == nil)
        #expect(step(&m, .key(.letter("a"))) == nil, "performing is still a session")
        #expect(step(&m, .performed) == .ended(performed: true))
    }

    @Test func everyOtherWayBackToIdleEndsWithoutAClick() {
        var cancelled = HintMachine<Int>(alphabet: .homeRow)
        _ = step(&cancelled, .trigger(.ready))
        _ = step(&cancelled, .scanned(ScanID(raw: 1), candidates()))
        #expect(step(&cancelled, .key(.escape)) == .ended(performed: false))

        var toggled = HintMachine<Int>(alphabet: .homeRow)
        _ = step(&toggled, .trigger(.ready))
        #expect(step(&toggled, .trigger(.ready)) == .ended(performed: false))

        var empty = HintMachine<Int>(alphabet: .homeRow)
        _ = step(&empty, .trigger(.ready))
        #expect(step(&empty, .scanned(ScanID(raw: 1), [])) == .ended(performed: false))

        var clicked = HintMachine<Int>(alphabet: .homeRow)
        _ = step(&clicked, .trigger(.ready))
        _ = step(&clicked, .scanned(ScanID(raw: 1), candidates()))
        #expect(step(&clicked, .mouseDown) == .ended(performed: false))

        var lost = HintMachine<Int>(alphabet: .homeRow)
        _ = step(&lost, .trigger(.ready))
        #expect(step(&lost, .keyCaptureLost) == .ended(performed: false))
    }

    @Test func idleStepsThatStartNothingProduceNoNote() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        #expect(step(&m, .configure(UserSettings(trigger: other))) == nil)
        #expect(step(&m, .mouseDown) == nil)
        #expect(step(&m, .key(.escape)) == nil)
        #expect(step(&m, .keyCaptureLost) == nil)
    }
}

struct MenuBarIconTests {
    private let measuredGap = 663.0..<848.0

    @Test func theMeasuredNotchGapHidesTheIcon() {
        #expect(MenuBarIcon.judge(itemMinX: 721, itemWidth: 38, notchGap: measuredGap, windowVisible: true) == .hidden)
    }

    @Test func anIconPartlyUnderTheNotchIsHidden() {
        #expect(MenuBarIcon.judge(itemMinX: 640, itemWidth: 38, notchGap: measuredGap, windowVisible: true) == .hidden)
        #expect(MenuBarIcon.judge(itemMinX: 830, itemWidth: 38, notchGap: measuredGap, windowVisible: true) == .hidden)
    }

    @Test func anIconBesideTheNotchIsVisibleOnlyWhenItsWindowIsVisible() {
        #expect(MenuBarIcon.judge(itemMinX: 1200, itemWidth: 38, notchGap: measuredGap, windowVisible: true) == .visible)
        #expect(MenuBarIcon.judge(itemMinX: 625, itemWidth: 38, notchGap: measuredGap, windowVisible: true) == .visible, "ends where the gap starts")
        #expect(MenuBarIcon.judge(itemMinX: 1200, itemWidth: 38, notchGap: measuredGap, windowVisible: false) == .hidden)
    }

    @Test func withoutANotchOnlyWindowVisibilityDecides() {
        #expect(MenuBarIcon.judge(itemMinX: 721, itemWidth: 38, notchGap: nil, windowVisible: true) == .visible)
        #expect(MenuBarIcon.judge(itemMinX: 721, itemWidth: 38, notchGap: nil, windowVisible: false) == .hidden)
    }

    @Test func anIconWithoutAWindowIsHidden() {
        #expect(MenuBarIcon.judge(itemMinX: nil, itemWidth: 38, notchGap: nil, windowVisible: true) == .hidden)
        #expect(MenuBarIcon.judge(itemMinX: 1200, itemWidth: 0, notchGap: nil, windowVisible: true) == .hidden)
    }
}
