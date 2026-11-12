import Testing
@testable import HintCore

struct ScanLaneTests {
    private let me = PID(1)

    private func extrasOnly(_ pid: Int32) -> AppScan {
        var job = AppScan(pid: PID(pid))
        job.statusItems = true
        return job
    }

    private func menuBar(_ pid: Int32) -> AppScan {
        var job = AppScan(pid: PID(pid))
        job.menuBar = true
        return job
    }

    private func assign(_ jobs: [AppScan]) -> [ScanLane] {
        ScanLane.assign(jobs, selfPID: me, lightLanes: 2, heavyLanes: 3)
    }

    @Test func ourOwnJobRunsOnMainWhateverItReads() {
        #expect(assign([menuBar(1)]) == [.main])
        #expect(assign([extrasOnly(1)]) == [.main])
    }

    @Test func extrasOnlyJobsTakeTheLightLanesInTurn() {
        #expect(assign([extrasOnly(10), extrasOnly(11), extrasOnly(12)]) == [.light(0), .light(1), .light(0)])
    }

    @Test func otherJobsTakeTheHeavyLanesInTurn() {
        #expect(assign([menuBar(10), menuBar(11), menuBar(12), menuBar(13)]) == [.heavy(0), .heavy(1), .heavy(2), .heavy(0)])
    }

    @Test func eachPoolKeepsItsOwnTurnAndOurJobTakesNone() {
        let lanes = assign([menuBar(10), extrasOnly(11), menuBar(1), menuBar(12), extrasOnly(13)])
        #expect(lanes == [.heavy(0), .light(0), .main, .heavy(1), .light(1)])
    }
}
