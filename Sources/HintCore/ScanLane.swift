/// Where one scan job's AX calls run. The shell maps `.light` and `.heavy` to its dispatch queues.
public enum ScanLane: Hashable, Sendable {
    /// Our own process. AX calls into it must run on the main thread.
    case main
    /// Index into the lanes for extras-only jobs, which cost one or two IPCs each.
    case light(Int)
    /// Index into the lanes for jobs that walk a window, a menu bar or the Dock.
    case heavy(Int)

    /// One lane per job, in the order of `jobs`.
    /// - Our own job is `.main`, and takes no index from either pool.
    /// - Extras-only jobs take the light lanes in turn, so they never queue behind a window walk.
    /// - Every other job takes the heavy lanes in turn.
    public static func assign(_ jobs: [AppScan], selfPID: PID, lightLanes: Int, heavyLanes: Int) -> [ScanLane] {
        var light = 0
        var heavy = 0
        return jobs.map { job in
            if job.pid == selfPID { return .main }
            if job.isExtrasOnly {
                defer { light += 1 }
                return .light(light % lightLanes)
            }
            defer { heavy += 1 }
            return .heavy(heavy % heavyLanes)
        }
    }
}
