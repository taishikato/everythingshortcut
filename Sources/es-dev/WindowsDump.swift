import Desktop
import HintCore

/// The AX-free half of a scan, printed. Uses the same `Desktop` reads and the same `ScanPlan`
/// as the app, so a wrong plan on the live desktop shows up here without Accessibility.
enum WindowsDump {
    static func render(snapshot: WindowSnapshot, displays: [Display], running: RunningApps) -> String {
        let selfPID = Desktop.selfPID
        let exposed = Set(snapshot.exposed(displays: displays, selfPID: selfPID).map(\.id))
        var lines = ["displays:"]
        for d in displays {
            lines.append("  \(d.id.raw) \(describe(d.bounds))")
        }
        lines.append("windows (front to back):")
        for w in snapshot.windows {
            let flags = [
                exposed.contains(w.id) ? "exposed" : "hidden",
                w.occludes(selfPID: selfPID) ? "occluder" : "transparent",
            ].joined(separator: ",")
            lines.append("  #\(w.id.raw) pid=\(w.owner.raw) \(w.ownerName) layer=\(w.layer) alpha=\(w.alpha) \(describe(w.bounds)) [\(flags)]")
        }
        let plan = ScanPlan.make(snapshot: snapshot, displays: displays, running: running, selfPID: selfPID)
        func pid(_ p: PID?) -> String { p.map { String($0.raw) } ?? "-" }
        lines.append("running: frontmost=\(pid(running.frontmost)) dock=\(pid(running.dock)) controlCenter=\(pid(running.controlCenter)) mayOwnStatusItems=\(running.mayOwnStatusItems.count)")
        lines.append("plan:")
        for app in plan.apps {
            var roots = app.windows.map { "window#\($0.id.raw)" }
            if app.menuBar { roots.insert("menuBar", at: 0) }
            if app.statusItems { roots.append("statusItems") }
            if app.dock { roots.append("dock") }
            lines.append("  pid=\(app.pid.raw): \(roots.joined(separator: " "))\(app.isExtrasOnly ? " (light lane, extras timeout)" : "")")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ r: GlobalRect) -> String {
        "(\(Int(r.x)),\(Int(r.y)) \(Int(r.width))x\(Int(r.height)))"
    }
}
