import Testing
@testable import HintCore

private func candidate(_ id: Int, x: Double, y: Double) -> Candidate<Int> {
    Candidate(target: id, pid: PID(1), surface: .window(WindowID(1)), frame: GlobalRect(x: x, y: y, width: 20, height: 10))
}

private func showing(_ count: Int) -> HintMachine<Int> {
    var m = HintMachine<Int>(alphabet: .homeRow)
    _ = m.send(.trigger(.ready))
    _ = m.send(.scanned(ScanID(raw: 1), (0..<count).map { candidate($0, x: Double($0) * 30, y: 0) }))
    return m
}

private func board(_ m: HintMachine<Int>) -> Board<Int>? {
    if case .showing(let b) = m.phase { return b }
    return nil
}

struct HintMachineTests {
    @Test func triggerStartsOneScanAndCapturesKeys() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        #expect(m.send(.trigger(.ready)) == [.captureKeys(true), .startScan(ScanID(raw: 1))])
        #expect(m.phase == .scanning(ScanID(raw: 1)))
    }

    @Test func blockedTriggerAlertsAndStaysIdle() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        #expect(m.send(.trigger(.blocked(.secureInputActive))) == [.alert(.secureInputActive)])
        #expect(m.phase == .idle)
    }

    @Test func triggerWhileScanningCancelsAndStaleResultIsDropped() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        _ = m.send(.trigger(.ready))
        #expect(m.send(.trigger(.ready)) == [.cancelScan, .captureKeys(false)])
        #expect(m.send(.scanned(ScanID(raw: 1), [candidate(0, x: 0, y: 0)])) == [])
        #expect(m.phase == .idle)
    }

    @Test func rapidTriggersYieldExactlyOneLiveScan() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        var effects: [Effect<Int>] = []
        for _ in 0..<3 { effects += m.send(.trigger(.ready)) }
        #expect(effects.filter { if case .startScan = $0 { true } else { false } }.count == 2)
        #expect(m.phase == .scanning(ScanID(raw: 2)))
        #expect(m.send(.scanned(ScanID(raw: 1), [candidate(0, x: 0, y: 0)])) == [])
        let shown = m.send(.scanned(ScanID(raw: 2), [candidate(0, x: 0, y: 0)]))
        #expect(shown.count == 1)
        #expect(board(m)?.hints.count == 1)
    }

    @Test func emptyScanReturnsToIdle() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        _ = m.send(.trigger(.ready))
        #expect(m.send(.scanned(ScanID(raw: 1), [])) == [.captureKeys(false), .alert(.noHints)])
        #expect(m.phase == .idle)
    }

    @Test func readingOrderGetsShortestLabelsFirst() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        _ = m.send(.trigger(.ready))
        _ = m.send(.scanned(ScanID(raw: 1), [candidate(7, x: 50, y: 100), candidate(8, x: 200, y: 0), candidate(9, x: 10, y: 100)]))
        let labels = board(m)?.hints.map { "\($0.label)=\($0.candidate.target)" }
        #expect(labels == ["s=8", "a=9", "d=7"])
    }

    @Test func exactLabelPerformsAndReleasesKeys() {
        var m = showing(3)
        #expect(m.send(.key(.letter("a"))) == [.render(nil), .captureKeys(false), .perform(1)])
        #expect(m.phase == .performing(1))
        #expect(m.send(.trigger(.ready)) == [])
        #expect(m.send(.performed) == [])
        #expect(m.phase == .idle)
    }

    @Test func letterMatchingNothingIsRejected() {
        var m = showing(3)
        #expect(m.send(.key(.letter("q"))) == [.alert(.noMatch)])
        #expect(board(m)?.typed == "")
    }

    @Test func prefixNarrowsAndBackspaceRestores() throws {
        var m = showing(40)
        let all = try #require(board(m)).hints
        let twoChar = try #require(all.first { $0.label.count == 2 })
        let first = try #require(twoChar.label.first)

        _ = m.send(.key(.letter(first)))
        let narrowed = try #require(board(m))
        #expect(narrowed.typed == String(first))
        #expect(narrowed.matching.allSatisfy { $0.label.hasPrefix(String(first)) })
        #expect(narrowed.matching.count < all.count)

        _ = m.send(.key(.backspace))
        #expect(board(m)?.typed == "")
        #expect(board(m)?.matching.count == all.count)
        #expect(m.send(.key(.backspace)) == [])
    }

    @Test func escapeAndTriggerBothCancelWhileShowing() {
        var a = showing(3)
        #expect(a.send(.key(.escape)) == [.render(nil), .captureKeys(false)])
        #expect(a.phase == .idle)
        var b = showing(3)
        #expect(b.send(.trigger(.ready)) == [.render(nil), .captureKeys(false)])
        #expect(b.phase == .idle)
    }

    @Test func mouseDownAnywhereCancelsWhileScanningOrShowing() {
        var scanning = HintMachine<Int>(alphabet: .homeRow)
        _ = scanning.send(.trigger(.ready))
        #expect(scanning.send(.mouseDown) == [.cancelScan, .captureKeys(false)])
        #expect(scanning.phase == .idle)
        var shown = showing(3)
        #expect(shown.send(.mouseDown) == [.render(nil), .captureKeys(false)])
        #expect(shown.phase == .idle)
    }

    @Test func mouseDownIsIgnoredWhenIdleOrPerforming() {
        var idle = HintMachine<Int>(alphabet: .homeRow)
        #expect(idle.send(.mouseDown) == [])
        #expect(idle.phase == .idle)
        var performing = showing(3)
        _ = performing.send(.key(.letter("a")))
        #expect(performing.send(.mouseDown) == [], "our own synthesized click must not end the perform")
        #expect(performing.phase == .performing(1))
    }

    @Test func lostKeyCaptureEndsTheSession() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        _ = m.send(.trigger(.ready))
        #expect(m.send(.keyCaptureLost) == [.cancelScan, .captureKeys(false), .alert(.keyCaptureLost)])
        var s = showing(2)
        #expect(s.send(.keyCaptureLost) == [.render(nil), .captureKeys(false), .alert(.keyCaptureLost)])
    }

    private let custom = UserSettings(trigger: HotKey(keyCode: 38, modifiers: [.control, .option, .command]))

    @Test func configureWhileIdleAppliesAtOnceAndKeepsThePhase() {
        var m = HintMachine<Int>(alphabet: .homeRow)
        #expect(m.send(.configure(custom)) == [.applySettings(custom)])
        #expect(m.phase == .idle)
    }

    @Test func configureWhileScanningWaitsForTheScanToEnd() {
        var cancelled = HintMachine<Int>(alphabet: .homeRow)
        _ = cancelled.send(.trigger(.ready))
        #expect(cancelled.send(.configure(custom)) == [])
        #expect(cancelled.send(.key(.escape)) == [.cancelScan, .captureKeys(false), .applySettings(custom)])

        var empty = HintMachine<Int>(alphabet: .homeRow)
        _ = empty.send(.trigger(.ready))
        _ = empty.send(.configure(custom))
        #expect(empty.send(.scanned(ScanID(raw: 1), [])) == [.captureKeys(false), .alert(.noHints), .applySettings(custom)])
    }

    @Test func configureWhileShowingWaitsThroughTypingUntilTheSessionEnds() throws {
        var m = showing(40)
        _ = m.send(.configure(custom))
        let first = try #require(board(m)?.hints.first { $0.label.count == 2 }?.label.first)
        let effects = m.send(.key(.letter(first)))
        let narrowed = try #require(board(m))
        #expect(effects == [.render(narrowed)])
        #expect(m.send(.keyCaptureLost) == [.render(nil), .captureKeys(false), .alert(.keyCaptureLost), .applySettings(custom)])
    }

    @Test func configureWhilePerformingWaitsForThePerform() {
        var m = showing(3)
        _ = m.send(.key(.letter("a")))
        #expect(m.send(.configure(custom)) == [])
        #expect(m.phase == .performing(1))
        #expect(m.send(.performed) == [.applySettings(custom)])
        #expect(m.phase == .idle)
    }

    @Test func onlyTheLastPendingConfigureApplies() {
        var m = showing(3)
        let other = UserSettings(trigger: .commandShiftSpace)
        _ = m.send(.configure(other))
        _ = m.send(.configure(custom))
        #expect(m.send(.key(.escape)) == [.render(nil), .captureKeys(false), .applySettings(custom)])
        #expect(m.send(.mouseDown) == [], "nothing stays pending once applied")
    }
}
