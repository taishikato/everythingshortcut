import Testing
@testable import HintCore

struct WindowMatchingTests {
    private func window(_ id: UInt32, _ x: Double) -> WindowInfo {
        WindowInfo(id: WindowID(id), owner: PID(1), ownerName: "A", layer: 0, alpha: 1, bounds: GlobalRect(x: x, y: 0, width: 100, height: 100))
    }

    private func pairs(_ result: WindowMatching.Result<Int>) -> [[Int]] {
        result.pairs.map { [Int($0.window.id.raw), $0.handle] }
    }

    @Test func windowsWithAnIdPairWithoutReadingAnyFrame() {
        var reads = 0
        let result = WindowMatching.pair(
            planned: [window(1, 0), window(2, 200)], identified: [WindowID(1): 10, WindowID(2): 20], unidentified: [30],
            frame: { (_: Int) throws(ReadError) -> GlobalRect? in reads += 1; return nil },
            shouldStop: { false }
        )
        #expect(pairs(result) == [[1, 10], [2, 20]])
        #expect(result.stop == nil)
        #expect(reads == 0)
    }

    @Test func windowsWithoutAnIdPairByFrameAndEachFrameIsReadOnce() {
        var reads: [Int] = []
        let frames = [30: window(3, 400).bounds, 40: window(4, 600).bounds]
        let result = WindowMatching.pair(
            planned: [window(1, 0), window(4, 600), window(3, 400), window(5, 800)], identified: [WindowID(1): 10], unidentified: [30, 40],
            frame: { (handle: Int) throws(ReadError) -> GlobalRect? in reads.append(handle); return frames[handle] },
            shouldStop: { false }
        )
        #expect(pairs(result) == [[1, 10], [4, 40], [3, 30]])
        #expect(result.stop == nil)
        #expect(reads == [30, 40], "three windows fell back to frames, and each frame still cost one read")
    }

    @Test func theDeadlineEndsFrameReadsAndKeepsThePairsById() {
        var reads = 0
        let result = WindowMatching.pair(
            planned: [window(3, 400), window(1, 0)], identified: [WindowID(1): 10], unidentified: [30],
            frame: { (_: Int) throws(ReadError) -> GlobalRect? in reads += 1; return self.window(3, 400).bounds },
            shouldStop: { true }
        )
        #expect(pairs(result) == [[1, 10]])
        #expect(result.stop == .budget)
        #expect(reads == 0)
    }

    @Test func anUnresponsiveAppEndsFrameReadsAtOnce() {
        var reads: [Int] = []
        let result = WindowMatching.pair(
            planned: [window(3, 400), window(4, 600)], identified: [:], unidentified: [30, 40],
            frame: { (handle: Int) throws(ReadError) -> GlobalRect? in reads.append(handle); throw .unresponsive },
            shouldStop: { false }
        )
        #expect(pairs(result).isEmpty)
        #expect(result.stop == .unresponsive)
        #expect(reads == [30])
    }

    @Test func aHandleWhoseFrameCannotBeReadStaysUnmatched() {
        let result = WindowMatching.pair(
            planned: [window(3, 400), window(4, 600)], identified: [:], unidentified: [30, 40],
            frame: { (handle: Int) throws(ReadError) -> GlobalRect? in
                if handle == 30 { throw .unavailable }
                return self.window(4, 600).bounds
            },
            shouldStop: { false }
        )
        #expect(pairs(result) == [[4, 40]])
        #expect(result.stop == nil)
    }
}
