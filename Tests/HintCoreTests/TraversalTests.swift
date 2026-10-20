import Testing
@testable import HintCore

/// An in-memory AX tree that records every call, so tests assert on IPC cost as well as results.
private final class FakeTree: ElementReader {
    struct Node {
        var facts: NodeFacts
        var children: [Int] = []
        var rows: [Int] = []
        var search: [Int]? = nil
        var unresponsive = false
    }

    var nodes: [Int: Node] = [:]
    private(set) var calls: [String] = []

    func add(_ id: Int, _ role: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, enabled: Bool = true, children: [Int] = []) {
        nodes[id] = Node(facts: NodeFacts(role: role, frame: GlobalRect(x: x, y: y, width: w, height: h), isEnabled: enabled), children: children)
    }

    func add(_ id: Int, _ role: String, frame: GlobalRect?, children: [Int] = []) {
        nodes[id] = Node(facts: NodeFacts(role: role, frame: frame), children: children)
    }

    func facts(of element: Int) throws(ReadError) -> NodeFacts {
        calls.append("facts \(element)")
        guard let node = nodes[element] else { throw .unavailable }
        if node.unresponsive { throw .unresponsive }
        return node.facts
    }

    func children(of element: Int, from source: ChildrenSource) throws(ReadError) -> [Int] {
        guard let node = nodes[element] else { throw .unavailable }
        switch source {
        case .children:
            calls.append("children \(element)")
            return node.children
        case .visibleRows:
            calls.append("rows \(element)")
            return node.rows
        case .searchPredicate:
            calls.append("search \(element)")
            guard let hits = node.search else { throw .unsupported }
            return hits
        }
    }

    func harvest(
        _ root: Int = 1,
        clip: GlobalRect = GlobalRect(x: 0, y: 0, width: 1000, height: 1000),
        maxNodes: Int = 1000,
        isFullyCovered: (GlobalRect) -> Bool = { _ in false },
        shouldStop: () -> Bool = { false }
    ) -> Harvest<Int> {
        Traversal.harvest(root: root, clip: clip, reader: self, roles: .standard, maxNodes: maxNodes, isFullyCovered: isFullyCovered, shouldStop: shouldStop)
    }
}

struct TraversalTests {
    @Test func offscreenSubtreeCostsOneCall() {
        let t = FakeTree()
        t.add(1, "AXWindow", 0, 0, 500, 500, children: [2, 3])
        t.add(2, "AXGroup", 600, 0, 100, 100, children: [4])
        t.add(3, "AXButton", 10, 10, 50, 20)
        t.add(4, "AXButton", 610, 10, 50, 20)
        let h = t.harvest()
        #expect(h.found.map(\.element) == [3])
        #expect(!t.calls.contains("children 2"))
        #expect(!t.calls.contains("facts 4"))
    }

    @Test func containersWithoutFramesPassTheClipThrough() {
        let t = FakeTree()
        t.add(1, "AXApplication", frame: nil, children: [2])
        t.add(2, "AXGroup", frame: nil, children: [3, 4, 6])
        t.add(3, "AXDockItem", 100, 900, 50, 50)
        t.add(4, "AXGroup", frame: .empty, children: [5])
        t.add(5, "AXButton", 200, 900, 50, 50)
        t.add(6, "AXGroup", 2000, 0, 100, 100, children: [7])
        t.add(7, "AXButton", 2010, 10, 50, 20)
        let h = t.harvest()
        #expect(h.found.map(\.element) == [3, 5])
        #expect(!t.calls.contains("children 6"), "a container with a frame outside the clip is still pruned")
    }

    @Test func subtreeBehindOneFrontWindowCostsOneCall() {
        let t = FakeTree()
        t.add(1, "AXWindow", 0, 0, 500, 500, children: [2, 5])
        t.add(2, "AXGroup", 0, 0, 200, 200, children: [3, 4])
        t.add(3, "AXButton", 10, 10, 50, 20)
        t.add(4, "AXButton", 10, 40, 50, 20)
        t.add(5, "AXButton", 300, 300, 50, 20)
        let front = GlobalRect(x: 0, y: 0, width: 250, height: 250)
        let h = t.harvest(isFullyCovered: { front.contains($0) })
        #expect(h.found.map(\.element) == [5])
        #expect(t.calls == ["facts 1", "children 1", "facts 2", "facts 5"])
    }

    @Test func hintsWithoutAVisibleFrameAreNotCandidates() {
        let t = FakeTree()
        t.add(1, "AXWindow", 0, 0, 500, 500, children: [2, 3, 4])
        t.add(2, "AXButton", frame: nil)
        t.add(3, "AXButton", frame: GlobalRect(x: 10, y: 10, width: 0, height: 20))
        t.add(4, "AXButton", 10, 40, 50, 20)
        #expect(t.harvest().found.map(\.element) == [4])
    }

    @Test func scrollAreasClipAndGroupsDoNot() {
        let t = FakeTree()
        t.add(1, "AXWindow", 0, 0, 500, 500, children: [2, 5])
        t.add(2, "AXScrollArea", 0, 0, 100, 100, children: [3, 4])
        t.add(3, "AXButton", 50, 50, 100, 100)
        t.add(4, "AXButton", 150, 0, 20, 20)
        t.add(5, "AXGroup", 200, 200, 10, 10, children: [6])
        t.add(6, "AXButton", 220, 220, 30, 30)
        let h = t.harvest()
        let frames = Dictionary(uniqueKeysWithValues: h.found.map { ($0.element, $0.visibleFrame) })
        #expect(frames[3] == GlobalRect(x: 50, y: 50, width: 50, height: 50))
        #expect(frames[4] == nil)
        #expect(frames[6] == GlobalRect(x: 220, y: 220, width: 30, height: 30))
    }

    @Test func hintsAndSkipsNeverReadChildrenAndDisabledIsNotHinted() {
        let t = FakeTree()
        t.add(1, "AXWindow", 0, 0, 500, 500, children: [2, 3, 4])
        t.add(2, "AXButton", 0, 0, 50, 20, children: [9])
        t.add(3, "AXStaticText", 0, 30, 50, 20, children: [9])
        t.add(4, "AXCheckBox", 0, 60, 50, 20, enabled: false)
        t.add(9, "AXButton", 0, 0, 10, 10)
        let h = t.harvest()
        #expect(h.found.map(\.element) == [2])
        #expect(!t.calls.contains("children 2"))
        #expect(!t.calls.contains("children 3"))
    }

    @Test func tablesReadVisibleRows() {
        let t = FakeTree()
        t.add(1, "AXTable", 0, 0, 500, 5000, children: Array(100..<200))
        t.nodes[1]?.rows = [2]
        t.add(2, "AXRow", 0, 0, 500, 20)
        let h = t.harvest()
        #expect(h.found.map(\.element) == [2])
        #expect(t.calls.contains("rows 1"))
        #expect(!t.calls.contains("children 1"))
    }

    @Test func webAreaSearchHitsAreTerminal() {
        let t = FakeTree()
        t.add(1, "AXWebArea", 0, 0, 500, 500)
        t.nodes[1]?.search = [2]
        t.add(2, "AXLink", 0, 0, 50, 20, children: [4])
        t.add(4, "AXLink", 0, 0, 10, 10)
        let h = t.harvest()
        #expect(h.found.map(\.element) == [2])
        #expect(!t.calls.contains("children 2"))
    }

    @Test func webSearchResultsPassThroughTheRoleTable() {
        let t = FakeTree()
        t.add(1, "AXWebArea", 0, 0, 500, 500)
        t.nodes[1]?.search = [2, 3, 4, 5, 6, 7]
        t.add(2, "AXLink", 0, 0, 50, 20)
        t.add(3, "AXGroup", 0, 30, 50, 20, children: [8])
        t.add(4, "AXStaticText", 0, 60, 50, 20)
        t.add(5, "AXButton", 0, 90, 50, 20, enabled: false)
        t.add(6, "AXTextField", 0, 120, 50, 20)
        t.add(7, "AXWebArea", 0, 150, 50, 20)
        t.add(8, "AXButton", 0, 30, 10, 10)
        let h = t.harvest()
        #expect(h.found.map(\.element) == [2, 6])
        #expect(!t.calls.contains("children 3") && !t.calls.contains("search 7"), "search results are never descended into")
    }

    @Test func webAreaWithoutSearchFallsBackToChildren() {
        let t = FakeTree()
        t.add(1, "AXWebArea", 0, 0, 500, 500, children: [2])
        t.add(2, "AXLink", 0, 0, 50, 20)
        let h = t.harvest()
        #expect(h.found.map(\.element) == [2])
        #expect(t.calls.contains("search 1") && t.calls.contains("children 1"))
    }

    @Test func everythingFoundUnderAWebAreaIsWebContent() {
        let t = FakeTree()
        t.add(1, "AXWindow", 0, 0, 500, 500, children: [2, 3, 4])
        t.add(2, "AXButton", 0, 0, 50, 20)
        t.add(3, "AXWebArea", 0, 100, 500, 100)
        t.nodes[3]?.search = [5]
        t.add(4, "AXWebArea", 0, 200, 500, 300, children: [6])
        t.add(5, "AXLink", 0, 100, 50, 20)
        t.add(6, "AXGroup", 0, 200, 500, 100, children: [7])
        t.add(7, "AXLink", 0, 200, 50, 20)
        let content = Dictionary(uniqueKeysWithValues: t.harvest().found.map { ($0.element, $0.content) })
        #expect(content == [2: .native, 5: .web, 7: .web], "search results and fallback descendants are web, the sibling button is native")
    }

    @Test func eachSearchedWebAreaReportsItsRawResultCount() {
        let t = FakeTree()
        t.add(1, "AXWindow", 0, 0, 500, 500, children: [2, 3, 4])
        t.add(2, "AXWebArea", 0, 0, 500, 100)
        t.nodes[2]?.search = []
        t.add(3, "AXWebArea", 0, 100, 500, 100)
        t.nodes[3]?.search = [5, 6]
        t.add(4, "AXWebArea", 0, 200, 500, 100, children: [7])
        t.add(5, "AXLink", 0, 100, 50, 20)
        t.add(6, "AXStaticText", 0, 130, 50, 20)
        t.add(7, "AXLink", 0, 200, 50, 20)
        let h = t.harvest()
        #expect(h.webAreaResults == [0, 2], "a web area without search support falls back and is not counted")
        #expect(h.found.map(\.element) == [5, 7])
    }

    @Test func unresponsiveAppStopsWithPartialResult() {
        let t = FakeTree()
        t.add(1, "AXWindow", 0, 0, 500, 500, children: [2, 3, 4])
        t.add(2, "AXButton", 0, 0, 50, 20)
        t.add(3, "AXButton", 0, 30, 50, 20)
        t.nodes[3]?.unresponsive = true
        t.add(4, "AXButton", 0, 60, 50, 20)
        let h = t.harvest()
        #expect(h.found.map(\.element) == [2])
        #expect(h.stop == .unresponsive)
        #expect(!t.calls.contains("facts 4"))
    }

    @Test func breadthFirstKeepsShallowControlsUnderTheNodeLimit() {
        let t = FakeTree()
        t.add(1, "AXWindow", 0, 0, 500, 500, children: [2, 3])
        t.add(2, "AXGroup", 0, 0, 500, 400, children: [4])
        t.add(3, "AXButton", 0, 450, 50, 20)
        t.add(4, "AXGroup", 0, 0, 500, 400, children: [5])
        t.add(5, "AXButton", 0, 0, 50, 20)
        let h = t.harvest(maxNodes: 3)
        #expect(h.found.map(\.element) == [3])
        #expect(h.stop == .nodeLimit)
    }

    @Test func deadlineStopsTheWalk() {
        let t = FakeTree()
        t.add(1, "AXWindow", 0, 0, 500, 500, children: [2])
        t.add(2, "AXButton", 0, 0, 50, 20)
        var checks = 0
        let h = t.harvest(shouldStop: { checks += 1; return checks > 2 })
        #expect(h.found.isEmpty)
        #expect(h.stop == .budget)
    }
}
