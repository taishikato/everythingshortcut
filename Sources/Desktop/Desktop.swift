import AppKit
import CoreGraphics
import HintCore

/// Read-only views of the live desktop. No AX, so es-dev can call these from an untrusted shell.
public enum Desktop {
    /// The on-screen window stack, front to back. The CGWindowList options live only here.
    /// Safe from any thread.
    public static func windowSnapshot() -> WindowSnapshot {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        return WindowSnapshot(cgWindowList: raw as? [[String: Any]] ?? [])
    }

    /// Active displays with their bounds in global display space. Safe from any thread.
    public static func displays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            Display(id: DisplayID(id), bounds: GlobalRect(CGDisplayBounds(id)))
        }
    }

    /// One NSWorkspace read for everything a scan plan needs beyond the window list.
    @MainActor
    public static func runningApps() -> RunningApps {
        let workspace = NSWorkspace.shared
        func pid(of bundleID: String) -> PID? {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first.map { PID($0.processIdentifier) }
        }
        return RunningApps(
            frontmost: workspace.frontmostApplication.map { PID($0.processIdentifier) },
            dock: pid(of: "com.apple.dock"),
            controlCenter: pid(of: "com.apple.controlcenter"),
            mayOwnStatusItems: workspace.runningApplications
                .filter { $0.activationPolicy != .prohibited }
                .map { PID($0.processIdentifier) }
        )
    }

    public static var selfPID: PID { PID(ProcessInfo.processInfo.processIdentifier) }
}

extension GlobalRect {
    public init(_ r: CGRect) { self.init(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height) }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension GlobalPoint {
    public init(_ p: CGPoint) { self.init(x: p.x, y: p.y) }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

extension AppKitRect {
    public init(_ r: NSRect) { self.init(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height) }

    public var nsRect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}
