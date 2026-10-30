import Testing
@testable import HintCore

private func facts(trusted: Bool = true, works: Bool = true) -> SetupFacts {
    SetupFacts(trusted: trusted, shortcutWorks: works)
}

private func firstRun(trusted: Bool = true, works: Bool = true) -> SetupGuide {
    SetupGuide(facts: facts(trusted: trusted, works: works), isComplete: false)
}

struct SetupGuideTests {
    @Test func firstRunWithoutAccessStartsAtAccess() {
        let g = firstRun(trusted: false)
        #expect(g.current == .access)
        #expect(g.isDone(.shortcut), "a working default shortcut is already checked")
        #expect(g.returnAction == .openSystemSettings)
    }

    @Test func aShortcutMacOSTakesIsCurrentOnceAccessIsAllowed() {
        let g = firstRun(works: false)
        #expect(g.current == .shortcut)
        #expect(g.returnAction == .recordShortcut)
    }

    @Test func accessComesBeforeABrokenShortcut() {
        let g = firstRun(trusted: false, works: false)
        #expect(g.current == .access)
        #expect(g.returnAction == .openSystemSettings)
    }

    @Test func aFirstRunWithBothStepsDoneFinishesOnReturn() {
        let g = firstRun()
        #expect(g.current == nil)
        #expect(g.returnAction == .finish)
    }

    @Test func aCompleteGuideWithNothingLeftHasNoReturnAction() {
        let g = SetupGuide(facts: facts(), isComplete: true)
        #expect(g.current == nil)
        #expect(g.returnAction == nil, "Done exists only during first-run setup")
    }

    @Test func grantingAccessComesForwardOnce() {
        var g = firstRun(trusted: false)
        #expect(g.send(.refreshed(facts(trusted: true))) == [.comeForward])
        #expect(g.current == nil)
        #expect(g.send(.refreshed(facts(trusted: true))) == [], "no second come-forward while nothing changed")
    }

    @Test func losingAccessDoesNotComeForward() {
        var g = firstRun()
        #expect(g.send(.refreshed(facts(trusted: false))) == [])
        #expect(g.current == .access)
    }

    @Test func askingForAccessSwitchesToTheWaitingCopyUntilDismissed() {
        var g = firstRun(trusted: false)
        #expect(!g.accessAsked)
        #expect(g.send(.askedForAccess) == [])
        #expect(g.accessAsked)
        _ = g.send(.dismissed)
        #expect(!g.accessAsked)
    }

    @Test func dismissingPersistsCompletionExactlyOnce() {
        var g = firstRun(trusted: false)
        #expect(g.send(.dismissed) == [.persistComplete])
        #expect(g.isComplete)
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
