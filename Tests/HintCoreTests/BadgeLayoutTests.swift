import Testing
@testable import HintCore

struct BadgeLayoutTests {
    private let primary = Display(id: DisplayID(1), bounds: GlobalRect(x: 0, y: 0, width: 1512, height: 982))
    private let left = Display(id: DisplayID(2), bounds: GlobalRect(x: -1920, y: -200, width: 1920, height: 1080))

    private func board(_ frames: [GlobalRect], typing: [Character] = []) -> Board<Int>? {
        var m = HintMachine<Int>(settings: .standard)
        _ = m.send(.trigger(.ready))
        _ = m.send(.scanned(ScanID(raw: 1), frames.enumerated().map { Candidate(target: $0, pid: PID(1), surface: .window(WindowID(1)), frame: $1) }))
        for c in typing { _ = m.send(.key(.letter(c))) }
        if case .showing(let b) = m.phase { return b }
        return nil
    }

    @Test func badgesGoToTheirDisplayInLocalCoordinates() throws {
        let b = try #require(board([
            GlobalRect(x: 100, y: 50, width: 40, height: 20),
            GlobalRect(x: -1900, y: -100, width: 40, height: 20),
        ]))
        let layout = BadgeLayout.layout(b, displays: [primary, left])
        #expect(layout.map(\.display.id) == [DisplayID(1), DisplayID(2)])
        #expect(layout[0].badges == [Badge(text: "A", typedCount: 0, origin: LocalPoint(x: 100, y: 50))])
        #expect(layout[1].badges == [Badge(text: "S", typedCount: 0, origin: LocalPoint(x: 20, y: 100))])
    }

    @Test func nonMatchingBadgesDisappearAndEmptyDisplaysAreOmitted() throws {
        let frames = (0..<20).map { GlobalRect(x: Double($0) * 50, y: 10, width: 40, height: 20) }
        let all = try #require(board(frames))
        let twoChar = try #require(all.hints.first { $0.label.count == 2 })
        let narrowed = try #require(board(frames, typing: [twoChar.label.first!]))
        let layout = BadgeLayout.layout(narrowed, displays: [primary, left])
        #expect(layout.count == 1)
        #expect(layout[0].badges.allSatisfy { $0.text.hasPrefix(String(twoChar.label.first!).uppercased()) && $0.typedCount == 1 })
    }
}
