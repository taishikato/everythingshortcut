import Testing
@testable import HintCore

struct KeyRoutingTests {
    private func route(_ code: UInt16, _ mods: Modifiers = [], _ c: Character? = nil, isRepeat: Bool = false) -> TapVerdict {
        KeyRouting.route(keyCode: code, modifiers: mods, isRepeat: isRepeat, character: c, trigger: .commandShiftSpace, alphabet: .homeRow)
    }

    @Test func triggerChordPassesThroughToCarbon() {
        #expect(route(VirtualKey.space, [.command, .shift]) == .passThrough)
    }

    @Test func otherChordsAreSwallowedAndDropped() {
        #expect(route(VirtualKey.space, [.command]) == .swallow(nil))
        #expect(route(13, [.command], "w") == .swallow(nil))
    }

    @Test func triggerChordIsNamedInMenuOrder() {
        #expect(HotKey.commandShiftSpace.displayName == "⇧⌘Space")
        #expect(HotKey(keyCode: VirtualKey.space, modifiers: [.command, .control, .option, .shift]).displayName == "⌃⌥⇧⌘Space")
    }

    @Test func escapeBackspaceAndLetters() {
        #expect(route(VirtualKey.escape) == .swallow(.escape))
        #expect(route(VirtualKey.delete) == .swallow(.backspace))
        #expect(route(1, [.shift], "S") == .swallow(.letter("s")))
        #expect(route(6, [], "z") == .swallow(nil))
    }

    @Test func aHeldKeyTypesItsLetterOnce() {
        #expect(route(1, [], "s") == .swallow(.letter("s")))
        #expect(route(1, [], "s", isRepeat: true) == .swallow(nil), "a repeat must not type the next letter of a label")
        #expect(route(VirtualKey.delete, isRepeat: true) == .swallow(.backspace))
        #expect(route(VirtualKey.escape, isRepeat: true) == .swallow(.escape))
        #expect(route(VirtualKey.space, [.command, .shift], isRepeat: true) == .passThrough)
    }
}

struct GeometryTests {
    @Test func appKitConversionRoundTrips() {
        let menuBar = GlobalRect(x: 0, y: 0, width: 1512, height: 33)
        let appKit = menuBar.appKitRect(primaryDisplayHeight: 982)
        #expect(appKit == AppKitRect(x: 0, y: 949, width: 1512, height: 33))
        #expect(GlobalRect(appKit, primaryDisplayHeight: 982) == menuBar)
    }

    @Test func displayAbovePrimaryStartsAtPrimaryHeightInAppKit() {
        let above = GlobalRect(x: 0, y: -1080, width: 1920, height: 1080)
        #expect(above.appKitRect(primaryDisplayHeight: 982).y == 982)
    }

    @Test func containmentIsHalfOpen() {
        let r = GlobalRect(x: 0, y: 0, width: 10, height: 10)
        #expect(r.contains(GlobalPoint(x: 0, y: 0)))
        #expect(!r.contains(GlobalPoint(x: 10, y: 5)))
        #expect(r.intersection(GlobalRect(x: 10, y: 0, width: 5, height: 5)).isEmpty)
    }
}

struct ActionPlanTests {
    private let hit = GlobalPoint(x: 5, y: 5)

    @Test func pressWhenAdvertisedRaisesWindowsOnly() {
        let window = ActionPlan.make(policy: .pressWhenAdvertised, surface: .window(WindowID(3)), hitPoint: hit, advertisedActions: ["AXPress"], content: .native)
        #expect(window == ActionPlan(raiseWindow: true, act: .press(fallback: hit)))
        let dock = ActionPlan.make(policy: .pressWhenAdvertised, surface: .dock, hitPoint: hit, advertisedActions: ["AXPress"], content: .native)
        #expect(dock == ActionPlan(raiseWindow: false, act: .press(fallback: hit)))
    }

    @Test func clickWhenPressIsMissingOrPolicySaysSo() {
        let field = ActionPlan.make(policy: .pressWhenAdvertised, surface: .window(WindowID(3)), hitPoint: hit, advertisedActions: ["AXConfirm"], content: .native)
        #expect(field.act == .click(hit))
        let forced = ActionPlan.make(policy: .alwaysClick, surface: .menuBar, hitPoint: hit, advertisedActions: ["AXPress"], content: .native)
        #expect(forced == ActionPlan(raiseWindow: false, act: .click(hit)))
    }

    @Test func webContentIsClickedEvenWhenPressIsAdvertised() {
        let link = ActionPlan.make(policy: .pressWhenAdvertised, surface: .window(WindowID(3)), hitPoint: hit, advertisedActions: ["AXPress"], content: .web)
        #expect(link == ActionPlan(raiseWindow: true, act: .click(hit)))
    }
}
