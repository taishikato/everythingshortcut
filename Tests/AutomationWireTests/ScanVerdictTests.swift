import Testing
@testable import AutomationWire

struct ScanVerdictTests {
    private func app(extrasOnly: Bool, roots: [String] = [], stop: String?) -> AppScanDump {
        AppScanDump(pid: 1, extrasOnly: extrasOnly, roots: roots, durationMs: 0, nodesRead: 0, stop: stop, candidates: 0, webAreaResults: [], webFlags: [:])
    }

    @Test func anExtrasOnlyJobTheBudgetNeverReachedIsStarvedNotCutShort() {
        let job = app(extrasOnly: true, stop: "budget")
        #expect(job.wasStarved)
        #expect(!job.wasCutShort)
    }

    @Test func anExtrasOnlyJobThatStartedItsWalkIsCutShort() {
        let job = app(extrasOnly: true, roots: ["statusItems"], stop: "budget")
        #expect(!job.wasStarved)
        #expect(job.wasCutShort)
    }

    @Test func aJobThatWalksAWindowIsCutShortEvenBeforeItsFirstRead() {
        let job = app(extrasOnly: false, stop: "budget")
        #expect(!job.wasStarved)
        #expect(job.wasCutShort, "its windows got no labels")
    }

    @Test func theNodeLimitAlwaysCutsShort() {
        #expect(app(extrasOnly: false, roots: ["window:1"], stop: "nodeLimit").wasCutShort)
        #expect(app(extrasOnly: true, roots: ["statusItems"], stop: "nodeLimit").wasCutShort)
    }

    @Test func anUnresponsiveAppOrAFinishedWalkIsNeither() {
        for stop in ["unresponsive", nil] {
            let job = app(extrasOnly: true, stop: stop)
            #expect(!job.wasStarved)
            #expect(!job.wasCutShort)
        }
    }
}
