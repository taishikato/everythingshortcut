import Testing
@testable import HintCore

/// The window stack observed in the grounding session, front to back, plus three app windows.
private enum Sample {
    static let me = PID(1)
    static let claude = PID(2)
    static let controlCenter = PID(3)
    static let windowServer = PID(4)
    static let dock = PID(5)
    static let appA = PID(10)
    static let appB = PID(20)
    static let appC = PID(30)
    static let loginwindow = PID(99)
    static let menuExtraApp = PID(40)

    static let displays = [Display(id: DisplayID(1), bounds: GlobalRect(x: 0, y: 0, width: 1512, height: 982))]

    static func w(_ id: UInt32, _ pid: PID, _ name: String, layer: Int, alpha: Double = 1, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> WindowInfo {
        WindowInfo(id: WindowID(id), owner: pid, ownerName: name, layer: layer, alpha: alpha, bounds: GlobalRect(x: x, y: y, width: width, height: height))
    }

    static let overlay = w(1, me, "EverythingShortcut", layer: WindowLayer.overlay, 0, 0, 1512, 982)
    static let invisible = w(2, claude, "Claude", layer: 26, alpha: 0, 0, 0, 1512, 65)
    static let wifi = w(3, controlCenter, "Control Center", layer: 25, 1400, 0, 40, 33)
    static let clock = w(4, controlCenter, "Control Center", layer: 25, 1450, 0, 60, 33)
    static let menuBar = w(5, windowServer, "Window Server", layer: 24, 0, 0, 1512, 33)
    static let dockWindow = w(6, dock, "Dock", layer: 20, 0, 900, 1512, 82)
    static let a = w(10, appA, "A", layer: 0, 100, 100, 800, 600)
    static let b = w(20, appB, "B", layer: 0, 500, 300, 800, 600)
    static let c = w(30, appC, "C", layer: 0, 200, 200, 300, 300)
    static let shield = w(98, loginwindow, "loginwindow", layer: 2004, 0, 0, 1512, 982)

    static let unlocked = WindowSnapshot(windows: [overlay, invisible, wifi, clock, menuBar, dockWindow, a, b, c])
    static let locked = WindowSnapshot(windows: [shield] + unlocked.windows)

    static func plan(_ s: WindowSnapshot) -> ScanPlan {
        let running = RunningApps(frontmost: appA, dock: dock, controlCenter: controlCenter, mayOwnStatusItems: [me, controlCenter, menuExtraApp, appA])
        return ScanPlan.make(snapshot: s, displays: displays, running: running, selfPID: me)
    }
}

struct WindowStackTests {
    @Test func planCoversMenuBarExtrasDockAndExposedWindows() {
        let apps = Dictionary(uniqueKeysWithValues: Sample.plan(Sample.unlocked).apps.map { ($0.pid, $0) })
        #expect(apps[Sample.appA]?.windows == [Sample.a])
        #expect(apps[Sample.appA]?.menuBar == true)
        #expect(apps[Sample.appB]?.windows == [Sample.b])
        #expect(apps[Sample.appB]?.menuBar == false)
        #expect(apps[Sample.appC] == nil, "C is entirely behind A")
        #expect(apps[Sample.controlCenter]?.statusItems == true)
        #expect(apps[Sample.menuExtraApp]?.statusItems == true, "third-party extras live in Control Center windows")
        #expect(apps[Sample.appA]?.statusItems == true)
        #expect(apps[Sample.appB]?.statusItems == false)
        #expect(apps[Sample.dock]?.dock == true)
        #expect(apps[Sample.me] == nil, "our only window here is the overlay, and our extras are never planned")
        #expect(apps[Sample.claude] == nil)
    }

    @Test func ourWindowIsPlannedButNotOurMenuBarOrExtras() {
        let settings = Sample.w(50, Sample.me, "EverythingShortcut", layer: 0, 300, 150, 480, 500)
        let snapshot = WindowSnapshot(windows: [Sample.overlay, Sample.wifi, Sample.menuBar, settings, Sample.a, Sample.dockWindow])
        let running = RunningApps(frontmost: Sample.me, dock: Sample.dock, controlCenter: Sample.controlCenter, mayOwnStatusItems: [Sample.me, Sample.controlCenter, Sample.appA])
        let apps = Dictionary(uniqueKeysWithValues: ScanPlan.make(snapshot: snapshot, displays: Sample.displays, running: running, selfPID: Sample.me).apps.map { ($0.pid, $0) })
        #expect(apps[Sample.me]?.windows == [settings])
        #expect(apps[Sample.me]?.menuBar == false, "pressing our own menu bar would run its menu inside the press")
        #expect(apps[Sample.me]?.statusItems == false)
        #expect(!apps.values.contains { $0.menuBar }, "while we are frontmost the menu bar on screen is ours, so nobody's is planned")
        #expect(apps[Sample.appA]?.windows == [Sample.a], "A sticks out from under our window")
        #expect(apps[Sample.appA]?.statusItems == true)
    }

    @Test func ourWindowOccludesAndOurOverlayDoesNot() {
        let settings = Sample.w(50, Sample.me, "EverythingShortcut", layer: 0, 300, 150, 480, 500)
        let underSettings = GlobalPoint(x: 400, y: 300)
        let covered = WindowSnapshot(windows: [Sample.overlay, settings, Sample.a])
        let onlyOverlay = WindowSnapshot(windows: [Sample.overlay, Sample.a])
        #expect(!Visibility.isVisible(underSettings, surface: .window(Sample.a.id), pid: Sample.appA, in: covered, selfPID: Sample.me))
        #expect(Visibility.isVisible(underSettings, surface: .window(Sample.a.id), pid: Sample.appA, in: onlyOverlay, selfPID: Sample.me))
        #expect(Visibility.isVisible(underSettings, surface: .window(settings.id), pid: Sample.me, in: covered, selfPID: Sample.me))
        let insideSettings = GlobalRect(x: 350, y: 200, width: 100, height: 50)
        #expect(Visibility.coverTest(surface: .window(Sample.a.id), pid: Sample.appA, in: covered, selfPID: Sample.me)(insideSettings))
        #expect(!Visibility.coverTest(surface: .window(Sample.a.id), pid: Sample.appA, in: onlyOverlay, selfPID: Sample.me)(insideSettings))
    }

    @Test func aWindowEntirelyBehindOursIsNotPlanned() {
        let settings = Sample.w(50, Sample.me, "EverythingShortcut", layer: 0, 0, 0, 1512, 982)
        let snapshot = WindowSnapshot(windows: [Sample.overlay, settings, Sample.c])
        let running = RunningApps(frontmost: Sample.me, dock: Sample.dock, controlCenter: Sample.controlCenter, mayOwnStatusItems: [])
        let plan = ScanPlan.make(snapshot: snapshot, displays: Sample.displays, running: running, selfPID: Sample.me)
        #expect(plan.apps.map(\.pid) == [Sample.me])
    }

    @Test func onlyAppsWithNothingButExtrasAreExtrasOnly() {
        let apps = Dictionary(uniqueKeysWithValues: Sample.plan(Sample.unlocked).apps.map { ($0.pid, $0) })
        #expect(apps[Sample.menuExtraApp]?.isExtrasOnly == true)
        #expect(apps[Sample.controlCenter]?.isExtrasOnly == true)
        #expect(apps[Sample.appA]?.isExtrasOnly == false, "windows and the menu bar too")
        #expect(apps[Sample.appB]?.isExtrasOnly == false)
        #expect(apps[Sample.dock]?.isExtrasOnly == false)
    }

    @Test func lockScreenShieldPlansNothing() {
        #expect(Sample.plan(Sample.locked).apps.isEmpty)
    }

    @Test func alphaZeroAndOwnWindowsDoNotOcclude() {
        let s = Sample.unlocked
        #expect(Visibility.isVisible(GlobalPoint(x: 50, y: 10), surface: .menuBar, pid: Sample.appA, in: s, selfPID: Sample.me))
        #expect(Visibility.isVisible(GlobalPoint(x: 1420, y: 10), surface: .statusItem, pid: Sample.menuExtraApp, in: s, selfPID: Sample.me))
    }

    @Test func backgroundWindowIsVisibleOnlyWhereUncovered() {
        let s = Sample.unlocked
        let underA = GlobalPoint(x: 600, y: 400)
        let exposed = GlobalPoint(x: 1200, y: 800)
        #expect(!Visibility.isVisible(underA, surface: .window(Sample.b.id), pid: Sample.appB, in: s, selfPID: Sample.me))
        #expect(Visibility.isVisible(exposed, surface: .window(Sample.b.id), pid: Sample.appB, in: s, selfPID: Sample.me))
        #expect(Visibility.isVisible(underA, surface: .window(Sample.a.id), pid: Sample.appA, in: s, selfPID: Sample.me))
    }

    @Test func coverTestCountsOnlyOccludersInFrontOfTheSurface() {
        let s = Sample.unlocked
        let insideAOverB = GlobalRect(x: 550, y: 350, width: 50, height: 50)
        let coveredForB = Visibility.coverTest(surface: .window(Sample.b.id), pid: Sample.appB, in: s, selfPID: Sample.me)
        let coveredForA = Visibility.coverTest(surface: .window(Sample.a.id), pid: Sample.appA, in: s, selfPID: Sample.me)
        #expect(coveredForB(insideAOverB))
        #expect(!coveredForB(GlobalRect(x: 1000, y: 700, width: 50, height: 50)), "that part of B is exposed")
        #expect(!coveredForB(GlobalRect(x: 850, y: 350, width: 100, height: 50)), "straddles A's edge, so one window does not contain it")
        #expect(!coveredForA(insideAOverB), "nothing opaque is in front of A there")
        let coveredForMenuBar = Visibility.coverTest(surface: .menuBar, pid: Sample.appA, in: s, selfPID: Sample.me)
        #expect(!coveredForMenuBar(GlobalRect(x: 0, y: 0, width: 1512, height: 65)), "the alpha-0 window and our overlay never cover")
    }

    @Test func dockItemHiddenByAnotherAppsWindowInFront() {
        let s = Sample.unlocked
        let dockPoint = GlobalPoint(x: 700, y: 950)
        #expect(Visibility.isVisible(dockPoint, surface: .dock, pid: Sample.dock, in: s, selfPID: Sample.me))
        #expect(!Visibility.isVisible(dockPoint, surface: .dock, pid: Sample.appA, in: s, selfPID: Sample.me), "anchor must be owned by the candidate's pid")
    }

    @Test func filterDropsCoveredOffscreenAndDuplicateCandidates() {
        func c(_ id: Int, _ pid: PID, _ surface: Surface, _ x: Double, _ y: Double) -> Candidate<Int> {
            Candidate(target: id, pid: pid, surface: surface, frame: GlobalRect(x: x, y: y, width: 20, height: 10))
        }
        let input = [
            c(1, Sample.appB, .window(Sample.b.id), 1200, 800),
            c(2, Sample.appB, .window(Sample.b.id), 600, 400),
            c(3, Sample.appB, .window(Sample.b.id), 1200, 800),
            c(4, Sample.appA, .window(Sample.a.id), -500, 400),
        ]
        let kept = Visibility.filter(input, snapshot: Sample.unlocked, displays: Sample.displays, selfPID: Sample.me, controlCenter: Sample.controlCenter)
        #expect(kept.candidates.map(\.target) == [1])
    }

    @Test func statusItemsDedupeByFrameKeepingTheOwnerAppOverControlCenter() {
        let wifiFrame = GlobalRect(x: 1405, y: 2, width: 30, height: 28)
        let clockFrame = GlobalRect(x: 1455, y: 2, width: 50, height: 28)
        let fromOwner = Candidate(target: 1, pid: Sample.menuExtraApp, surface: .statusItem, frame: wifiFrame)
        let fromControlCenter = Candidate(target: 2, pid: Sample.controlCenter, surface: .statusItem, frame: wifiFrame)
        let clock = Candidate(target: 3, pid: Sample.controlCenter, surface: .statusItem, frame: clockFrame)
        for input in [[fromControlCenter, clock, fromOwner], [fromOwner, fromControlCenter, clock]] {
            let result = Visibility.filter(input, snapshot: Sample.unlocked, displays: Sample.displays, selfPID: Sample.me, controlCenter: Sample.controlCenter)
            #expect(Set(result.candidates.map(\.target)) == [1, 3])
            #expect(result.droppedStatusItems == [StatusItemDuplicate(frame: wifiFrame, kept: Sample.menuExtraApp, dropped: Sample.controlCenter)])
        }
    }

    @Test func otherSurfacesStillDedupeByPidAndFrame() {
        let frame = GlobalRect(x: 1200, y: 800, width: 20, height: 10)
        let input = [
            Candidate(target: 1, pid: Sample.appB, surface: .window(Sample.b.id), frame: frame),
            Candidate(target: 2, pid: Sample.appA, surface: .window(Sample.b.id), frame: frame),
        ]
        let result = Visibility.filter(input, snapshot: Sample.unlocked, displays: Sample.displays, selfPID: Sample.me, controlCenter: Sample.controlCenter)
        #expect(result.candidates.map(\.target) == [1, 2])
        #expect(result.droppedStatusItems.isEmpty)
    }

    @Test func parsesCGWindowListEntries() {
        let raw: [[String: Any]] = [
            ["kCGWindowNumber": 42, "kCGWindowOwnerPID": 7, "kCGWindowOwnerName": "Finder", "kCGWindowLayer": 0,
             "kCGWindowAlpha": 1.0, "kCGWindowBounds": ["X": 10.0, "Y": 20.0, "Width": 300.0, "Height": 200.0]],
            ["kCGWindowNumber": 43],
        ]
        let s = WindowSnapshot(cgWindowList: raw)
        #expect(s.windows == [WindowInfo(id: WindowID(42), owner: PID(7), ownerName: "Finder", layer: 0, alpha: 1, bounds: GlobalRect(x: 10, y: 20, width: 300, height: 200))])
    }
}
