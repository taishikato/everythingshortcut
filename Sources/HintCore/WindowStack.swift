public struct PID: Hashable, Sendable, Comparable {
    public let raw: Int32

    public init(_ raw: Int32) { self.raw = raw }

    public static func < (a: PID, b: PID) -> Bool { a.raw < b.raw }
}

public struct WindowID: Hashable, Sendable {
    public let raw: UInt32

    public init(_ raw: UInt32) { self.raw = raw }
}

/// CGWindowLevel values (CGWindowLevel.h). Hardcoded because the core does not import
/// CoreGraphics. The app asserts them against `CGWindowLevelForKey` at launch in DEBUG.
public enum WindowLayer {
    public static let dock = 20
    public static let mainMenu = 24
    public static let status = 25
}

/// One on-screen window from `CGWindowListCopyWindowInfo`.
public struct WindowInfo: Hashable, Sendable {
    public let id: WindowID
    public let owner: PID
    public let ownerName: String
    public let layer: Int
    public let alpha: Double
    public let bounds: GlobalRect

    public init(id: WindowID, owner: PID, ownerName: String, layer: Int, alpha: Double, bounds: GlobalRect) {
        self.id = id
        self.owner = owner
        self.ownerName = ownerName
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }

    /// Whether this window can hide what is behind it.
    /// Alpha-0 windows (the invisible 1512x65 window in the grounding sample) and our own
    /// overlay never occlude.
    public func occludes(selfPID: PID) -> Bool { alpha > 0 && owner != selfPID && !bounds.isEmpty }
}

/// The on-screen window stack, front to back. Taken once per scan and shared by the plan
/// and the occlusion filter, so both judge visibility against the same stack.
public struct WindowSnapshot: Hashable, Sendable {
    public let windows: [WindowInfo]

    public init(windows: [WindowInfo]) { self.windows = windows }

    /// Boundary parser for `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`.
    /// The keys are the string values of the kCGWindow* constants. Entries missing a required
    /// key are dropped. Order is preserved, so the result stays front to back.
    public init(cgWindowList: [[String: Any]]) {
        windows = cgWindowList.compactMap { entry in
            guard let number = entry["kCGWindowNumber"] as? Int,
                  let pid = entry["kCGWindowOwnerPID"] as? Int,
                  let layer = entry["kCGWindowLayer"] as? Int,
                  let b = entry["kCGWindowBounds"] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let w = b["Width"] as? Double, let h = b["Height"] as? Double
            else { return nil }
            return WindowInfo(
                id: WindowID(UInt32(truncatingIfNeeded: number)),
                owner: PID(Int32(truncatingIfNeeded: pid)),
                ownerName: entry["kCGWindowOwnerName"] as? String ?? "",
                layer: layer,
                alpha: entry["kCGWindowAlpha"] as? Double ?? 1,
                bounds: GlobalRect(x: x, y: y, width: w, height: h)
            )
        }
    }

    /// Windows that are on some display and not entirely inside a single occluding window in front.
    /// A cheap, conservative cover test. Partially covered windows stay exposed and the per-element
    /// occlusion test handles them. A lock screen or screensaver shield hides everything behind it.
    public func exposed(displays: [Display], selfPID: PID) -> [WindowInfo] {
        let screen = displays.unionBounds
        var occludersInFront: [GlobalRect] = []
        var result: [WindowInfo] = []
        for w in windows {
            defer { if w.occludes(selfPID: selfPID) { occludersInFront.append(w.bounds) } }
            guard w.owner != selfPID, w.alpha > 0 else { continue }
            let onScreen = w.bounds.intersection(screen)
            guard !onScreen.isEmpty, !occludersInFront.contains(where: { $0.contains(onScreen) }) else { continue }
            result.append(w)
        }
        return result
    }
}

/// Where a candidate is drawn, which decides its z-position and whether a click raises a window.
public enum Surface: Hashable, Sendable {
    /// Inside an app window. The id comes from `_AXUIElementGetWindow` on the traversal root.
    case window(WindowID)
    /// The frontmost app's menu bar, drawn in the main-menu-level window.
    case menuBar
    /// A menu bar extra, drawn in a status-level window. On macOS 26 Control Center owns every
    /// status-level window, third-party extras included, so the anchor ignores the owner.
    case statusItem
    /// A Dock item, drawn in a Dock-level window owned by the Dock.
    case dock

    /// Whether `w` is the window this surface draws into, for a candidate of `pid`.
    func isAnchor(_ w: WindowInfo, pid: PID) -> Bool {
        switch self {
        case .window(let id): return w.id == id
        case .menuBar: return w.layer == WindowLayer.mainMenu
        case .statusItem: return w.layer == WindowLayer.status
        case .dock: return w.owner == pid && w.layer == WindowLayer.dock
        }
    }
}

/// What to traverse in one app. One probe actor per entry.
public struct AppScan: Hashable, Sendable {
    public let pid: PID
    /// Exposed app windows, front to back. The probe matches AX windows to these by id.
    public var windows: [WindowInfo] = []
    /// Traverse `AXMenuBar`. Only the frontmost app's menu bar is on screen.
    public var menuBar = false
    /// Traverse `AXExtrasMenuBar`. True for every app that may own extras, when any status-level window is exposed.
    public var statusItems = false
    /// Traverse the app element's children. True only for the Dock with an exposed Dock window.
    public var dock = false

    public init(pid: PID) { self.pid = pid }
}

/// What the window list cannot say about running apps. Read from NSWorkspace at trigger time.
public struct RunningApps: Hashable, Sendable {
    public var frontmost: PID?
    public var dock: PID?
    /// Found by bundle id `com.apple.controlcenter`. On macOS 26 it may expose another app's extra
    /// as its own, so status-item deduplication prefers every other owner over it.
    public var controlCenter: PID?
    /// Regular and accessory apps. Any of them may own a menu bar extra, and on macOS 26 the window
    /// list attributes every extra's window to Control Center, so it cannot narrow this set.
    public var mayOwnStatusItems: [PID]

    public init(frontmost: PID?, dock: PID?, controlCenter: PID?, mayOwnStatusItems: [PID]) {
        self.frontmost = frontmost
        self.dock = dock
        self.controlCenter = controlCenter
        self.mayOwnStatusItems = mayOwnStatusItems
    }
}

public struct ScanPlan: Hashable, Sendable {
    /// Sorted by pid so the plan is deterministic for tests and logs.
    public let apps: [AppScan]

    /// Derives the whole scan from one window snapshot plus the running-app list.
    /// - App windows: exposed windows below Dock level, per owner.
    /// - Menu bar: the frontmost app, when an exposed main-menu-level window exists.
    /// - Menu bar extras: every app in `mayOwnStatusItems`, when any status-level window is exposed.
    ///   Each costs one `AXExtrasMenuBar` read, and most apps answer it with no value.
    /// - Dock: the Dock pid, when it owns an exposed Dock-level window. A hidden Dock is skipped.
    /// Our own pid is never planned. AX calls into our own process would have to run on main.
    /// A lock screen or screensaver shield leaves nothing exposed, so the plan is empty.
    public static func make(
        snapshot: WindowSnapshot,
        displays: [Display],
        running: RunningApps,
        selfPID: PID
    ) -> ScanPlan {
        var apps: [PID: AppScan] = [:]
        func edit(_ pid: PID, _ change: (inout AppScan) -> Void) {
            guard pid != selfPID else { return }
            change(&apps[pid, default: AppScan(pid: pid)])
        }
        var statusWindowExposed = false
        for w in snapshot.exposed(displays: displays, selfPID: selfPID) {
            switch w.layer {
            case ..<WindowLayer.dock:
                edit(w.owner) { $0.windows.append(w) }
            case WindowLayer.dock where w.owner == running.dock:
                edit(w.owner) { $0.dock = true }
            case WindowLayer.mainMenu:
                if let frontmost = running.frontmost { edit(frontmost) { $0.menuBar = true } }
            case WindowLayer.status:
                statusWindowExposed = true
            default:
                continue
            }
        }
        if statusWindowExposed {
            for pid in running.mayOwnStatusItems { edit(pid) { $0.statusItems = true } }
        }
        return ScanPlan(apps: apps.values.sorted { $0.pid < $1.pid })
    }
}

public enum Visibility {
    /// Whether a click at `point` would land on `surface`.
    ///
    /// Find the anchor window (the window the surface draws into that contains `point`), then
    /// require that no occluding window in front of it contains `point`. Alpha-0 windows and our own
    /// windows never occlude. No anchor means the element is not on screen.
    public static func isVisible(
        _ point: GlobalPoint,
        surface: Surface,
        pid: PID,
        in snapshot: WindowSnapshot,
        selfPID: PID
    ) -> Bool {
        for w in snapshot.windows {
            if surface.isAnchor(w, pid: pid), w.bounds.contains(point) { return true }
            if w.occludes(selfPID: selfPID), w.bounds.contains(point) { return false }
        }
        return false
    }

    /// A cover test for `Traversal.harvest` on one root. True only when a single occluding window in
    /// front of the window `surface` draws into contains all of the rect, so nothing in it can be seen.
    /// Rects hidden by several windows together return false, and `filter` settles those later.
    public static func coverTest(surface: Surface, pid: PID, in snapshot: WindowSnapshot, selfPID: PID) -> (GlobalRect) -> Bool {
        var inFront: [GlobalRect] = []
        for w in snapshot.windows {
            if surface.isAnchor(w, pid: pid) { break }
            if w.occludes(selfPID: selfPID) { inFront.append(w.bounds) }
        }
        return { rect in inFront.contains { $0.contains(rect) } }
    }

    /// Keeps candidates whose hit point is on a display and not covered, then drops duplicates.
    /// Order is preserved.
    ///
    /// Menu bar extras deduplicate by frame alone, because one extra may be exposed both by its owner
    /// app and by Control Center. The winner does not depend on input order: any app beats Control
    /// Center, then the lower pid wins. Every other surface deduplicates by pid and frame, first wins.
    public static func filter<Target>(
        _ candidates: [Candidate<Target>],
        snapshot: WindowSnapshot,
        displays: [Display],
        selfPID: PID,
        controlCenter: PID?
    ) -> VisibleCandidates<Target> {
        let visible = candidates.filter { c in
            displays.containing(c.hitPoint) != nil
                && isVisible(c.hitPoint, surface: c.surface, pid: c.pid, in: snapshot, selfPID: selfPID)
        }

        func rank(_ i: Int) -> (Int, PID, Int) { (visible[i].pid == controlCenter ? 1 : 0, visible[i].pid, i) }
        var statusWinner: [GlobalRect: Int] = [:]
        for (i, c) in visible.enumerated() where c.surface == .statusItem {
            if let current = statusWinner[c.frame], rank(current) < rank(i) { continue }
            statusWinner[c.frame] = i
        }

        var seen = Set<DedupeKey>()
        var kept: [Candidate<Target>] = []
        var dropped: [StatusItemDuplicate] = []
        for (i, c) in visible.enumerated() {
            if c.surface == .statusItem {
                if let winner = statusWinner[c.frame], winner != i {
                    dropped.append(StatusItemDuplicate(frame: c.frame, kept: visible[winner].pid, dropped: c.pid))
                    continue
                }
            } else {
                guard seen.insert(DedupeKey(pid: c.pid, frame: c.frame)).inserted else { continue }
            }
            kept.append(c)
        }
        return VisibleCandidates(candidates: kept, droppedStatusItems: dropped)
    }
}

public struct VisibleCandidates<Target: Sendable>: Sendable {
    public let candidates: [Candidate<Target>]
    /// Menu bar extras dropped because another element had the same frame.
    public let droppedStatusItems: [StatusItemDuplicate]
}

public struct StatusItemDuplicate: Hashable, Sendable {
    public let frame: GlobalRect
    public let kept: PID
    public let dropped: PID

    public init(frame: GlobalRect, kept: PID, dropped: PID) {
        self.frame = frame
        self.kept = kept
        self.dropped = dropped
    }
}

private struct DedupeKey: Hashable {
    let pid: PID
    let frame: GlobalRect
}
