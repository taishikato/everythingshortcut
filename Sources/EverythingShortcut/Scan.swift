import ApplicationServices
import CoreGraphics
import Darwin
import Desktop
import Dispatch
import Foundation
import HintCore

/// What one app contributed to a scan, for the log and the DEBUG snapshot.
struct AppScanStats: Sendable {
    let pid: PID
    let roots: [String]
    let duration: Duration
    let nodesRead: Int
    /// Nil when every planned root was walked to the end.
    let stop: StopReason?
    let candidates: Int
    let webAreaResults: [Int]
    let webFlags: [String: String]
}

struct ScanStats: Sendable {
    let duration: Duration
    /// Sorted by pid.
    let apps: [AppScanStats]
    let candidatesBeforeOcclusion: Int
    let candidates: Int
    let droppedStatusItems: [StatusItemDuplicate]

    var nodesRead: Int { apps.reduce(0) { $0 + $1.nodesRead } }
}

struct ScanReport: Sendable {
    let candidates: [Candidate<ElementRef>]
    let stats: ScanStats
}

/// One scan of the whole visible desktop.
struct Scanner: Sendable {
    let config: HintConfig

    /// Bounds every AX IPC this process makes. The system-wide element sets the process-wide value.
    static func setProcessMessagingTimeout(_ timeout: Duration) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Float(timeout / .seconds(1)))
    }

    /// Snapshot the window stack, plan from it, fan out one probe per app, then apply occlusion
    /// against the same snapshot. `running` comes from NSWorkspace on the main actor.
    ///
    /// `@concurrent` keeps this off the caller's actor, so the main thread only sends the trigger
    /// and receives the result. Cancellation reaches every probe through `Task.isCancelled`.
    /// Returns by `scanBudget + axMessagingTimeout` (see `AppProbe`).
    @concurrent
    func scan(_ running: RunningApps) async -> ScanReport {
        let start = ContinuousClock.now
        let deadline = start + config.scanBudget
        let snapshot = Desktop.windowSnapshot()
        let displays = Desktop.displays()
        let selfPID = Desktop.selfPID
        let plan = ScanPlan.make(snapshot: snapshot, displays: displays, running: running, selfPID: selfPID)
        let config = config
        let harvests = await withTaskGroup(of: AppHarvest.self, returning: [AppHarvest].self) { group in
            for (job, lane) in ProbeQueues.assign(plan.apps, selfPID: selfPID) {
                group.addTask {
                    await AppProbe(pid: job.pid, lane: lane, config: config)
                        .scan(job, snapshot: snapshot, displays: displays, selfPID: selfPID, deadline: deadline)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        .sorted { $0.stats.pid < $1.stats.pid }
        let found = harvests.flatMap(\.candidates)
        let visible = Visibility.filter(found, snapshot: snapshot, displays: displays, selfPID: selfPID, controlCenter: running.controlCenter)
        let stats = ScanStats(
            duration: ContinuousClock.now - start,
            apps: harvests.map(\.stats),
            candidatesBeforeOcclusion: found.count,
            candidates: visible.candidates.count,
            droppedStatusItems: visible.droppedStatusItems
        )
        return ScanReport(candidates: visible.candidates, stats: stats)
    }
}

/// A handle to one element found by a scan.
/// Sendable because it holds only the actor that owns the element and an index into that actor's slots.
/// The `AXUIElement` itself never leaves the actor that created it.
struct ElementRef: Sendable {
    let probe: AppProbe
    let slot: Int

    func perform() async -> PerformReport {
        await probe.perform(slot: slot)
    }
}

/// What one perform did, for the log and the DEBUG snapshot.
struct PerformReport: Sendable {
    enum Act: Sendable {
        /// `AXPress` answered success or cannotComplete, which counts as done.
        case pressed(AXError)
        /// `AXPress` failed, so the probe clicked instead.
        case pressFailedThenClicked(AXError)
        case clicked
    }

    let pid: PID
    let surface: Surface
    let plan: ActionPlan
    let act: Act
    /// Read from the app element's `AXFrontmost`. Nil when the app did not answer.
    let frontmostBefore: Bool?
    let frontmostAfter: Bool?
}

/// What one app contributed to a scan.
struct AppHarvest: Sendable {
    let candidates: [Candidate<ElementRef>]
    let stats: AppScanStats
}

/// One app's AX connection for one hint session.
///
/// Ownership. The probe creates and owns every `AXUIElement` of its app for this session, in `slots`.
/// Everything that leaves it is a Sendable value: `Candidate<ElementRef>` out of `scan`, a
/// `PerformReport` out of `perform`. The session's board keeps the probe alive through its
/// `ElementRef`s. Dropping the board (cancel, perform done, next trigger) releases the probe and its elements.
///
/// Threading. The actor's executor is its `ProbeLane`. For another app it is a serial dispatch queue
/// from `ProbeQueues`: AX calls are blocking Mach IPC, so they never run on a Swift cooperative-pool
/// thread. Apps on different queues scan in parallel. One app's roots run in sequence, since the target
/// app answers AX on its main thread anyway. Probes sharing a queue are separate actors that take turns
/// on it. For our own process it is the main actor's executor (see `ProbeLane.main`).
///
/// Deadline. Every IPC is bounded by a messaging timeout, and the probe checks the scan deadline
/// before each IPC. So `scan` returns by `deadline + axMessagingTimeout` with no watchdog task.
actor AppProbe {
    nonisolated let pid: PID
    private let lane: ProbeLane
    private let config: HintConfig
    private let app: AXUIElement
    private let reader = AXReader()
    private var slots: [Slot] = []

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        switch lane {
        case .queue(let queue): queue.asUnownedSerialExecutor()
        case .main: MainActor.sharedUnownedExecutor
        }
    }

    init(pid: PID, lane: ProbeLane, config: HintConfig) {
        self.pid = pid
        self.lane = lane
        self.config = config
        app = AXUIElementCreateApplication(pid.raw)
    }

    /// Walks the roots that `job` names and returns candidates clipped to their windows and scroll areas.
    /// Subtrees hidden behind one front window are skipped during the walk. The full occlusion test
    /// runs later in `Scanner`, against the same snapshot.
    func scan(_ job: AppScan, snapshot: WindowSnapshot, displays: [Display], selfPID: PID, deadline: ContinuousClock.Instant) -> AppHarvest {
        let start = ContinuousClock.now
        let screen = displays.unionBounds
        let shouldStop = { Task.isCancelled || ContinuousClock.now >= deadline }
        var candidates: [Candidate<ElementRef>] = []
        var rootNames: [String] = []
        var nodesRead = 0
        var stop: StopReason?
        var webAreaResults: [Int] = []
        var webFlags: [String: String] = [:]

        func finish() -> AppHarvest {
            AppHarvest(candidates: candidates, stats: AppScanStats(
                pid: pid, roots: rootNames, duration: ContinuousClock.now - start, nodesRead: nodesRead,
                stop: stop, candidates: candidates.count, webAreaResults: webAreaResults, webFlags: webFlags
            ))
        }

        /// Reads one root attribute of the app element. Nil when the scan must end or the value is absent.
        func rootAttribute<T>(_ read: () throws(ReadError) -> T?) -> T? {
            guard stop == nil else { return nil }
            if shouldStop() { stop = .budget; return nil }
            do throws(ReadError) {
                return try read()
            } catch {
                if error == .unresponsive { stop = .unresponsive }
                return nil
            }
        }

        if job.isExtrasOnly {
            AXUIElementSetMessagingTimeout(app, Float(config.extrasMessagingTimeout / .seconds(1)))
        }

        // The liveness check. Reading the app element's role is also what turns on Chromium's basic
        // web accessibility (chrome_browser_application_mac.mm:488-505) for the life of the process,
        // and Arc drops its tree when idle, so it runs on every scan that traverses a window, menu bar
        // or Dock. An extras-only job skips it: its one `AXExtrasMenuBar` read is the liveness check,
        // and it never wakes accessibility in a Chromium app whose windows we do not walk.
        if !job.isExtrasOnly {
            guard rootAttribute({ () throws(ReadError) in try reader.string(app, kAXRoleAttribute) }) != nil else { return finish() }
        }

        var roots: [Root] = []
        if job.menuBar, let menuBar = rootAttribute({ () throws(ReadError) in try reader.element(app, kAXMenuBarAttribute) }) {
            roots.append(Root(name: "menuBar", element: menuBar, clip: screen, surface: .menuBar, window: nil))
        }
        if !job.windows.isEmpty, let axWindows = rootAttribute({ () throws(ReadError) in try reader.elements(app, kAXWindowsAttribute) }) {
            let matched = match(job.windows, among: axWindows, shouldStop: shouldStop)
            stop = matched.stop
            for (info, window) in matched.pairs {
                roots.append(Root(name: "window:\(info.id.raw)", element: window, clip: info.bounds.intersection(screen), surface: .window(info.id), window: window))
            }
        }
        if job.statusItems, let extras = rootAttribute({ () throws(ReadError) in try reader.element(app, "AXExtrasMenuBar") }) {
            roots.append(Root(name: "statusItems", element: extras, clip: screen, surface: .statusItem, window: nil))
        }
        if job.dock {
            roots.append(Root(name: "dock", element: app, clip: screen, surface: .dock, window: nil))
        }

        for root in roots where stop == nil {
            rootNames.append(root.name)
            let harvest = Traversal.harvest(
                root: root.element,
                clip: root.clip,
                reader: reader,
                roles: config.roles,
                maxNodes: config.maxNodesPerApp - nodesRead,
                isFullyCovered: Visibility.coverTest(surface: root.surface, pid: pid, in: snapshot, selfPID: selfPID),
                shouldStop: shouldStop
            )
            nodesRead += harvest.nodesRead
            stop = harvest.stop
            webAreaResults += harvest.webAreaResults
            for found in harvest.found {
                let candidate = Candidate(target: ElementRef(probe: self, slot: slots.count), pid: pid, surface: root.surface, frame: found.visibleFrame)
                slots.append(Slot(element: found.element, window: root.window, surface: root.surface, hitPoint: candidate.hitPoint, content: found.content))
                candidates.append(candidate)
            }
        }

        if webAreaResults.contains(0), stop != .unresponsive {
            webFlags = enableWebAccessibility(shouldStop: shouldStop)
        }
        return finish()
    }

    /// Pairs each planned window with its AX window: by `_AXUIElementGetWindow` id, else by an equal frame.
    /// `WindowMatching.pair` decides, and reads each unidentified window's frame at most once, under the deadline.
    private func match(_ planned: [WindowInfo], among axWindows: [AXUIElement], shouldStop: () -> Bool) -> WindowMatching.Result<AXUIElement> {
        var byID: [WindowID: AXUIElement] = [:]
        var unidentified: [AXUIElement] = []
        for window in axWindows {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(window, &id) == .success, id != 0 {
                byID[WindowID(id)] = window
            } else {
                unidentified.append(window)
            }
        }
        return WindowMatching.pair(
            planned: planned, identified: byID, unidentified: unidentified,
            frame: { (window: AXUIElement) throws(ReadError) -> GlobalRect? in try reader.facts(of: window).frame },
            shouldStop: shouldStop
        )
    }

    /// Chromium honors `AXEnhancedUserInterface` after a 2 s quiet window, Electron honors
    /// `AXManualAccessibility`. Each is read first and written only when not already true, so repeated
    /// scans do not restart Chromium's timer. Never written false: that destroys Chromium's web tree.
    /// `shouldStop` is checked before each IPC, so a scan that is cancelled or past its deadline writes
    /// nothing, and the next scan that sees the empty web area tries again.
    private func enableWebAccessibility(shouldStop: () -> Bool) -> [String: String] {
        var outcome: [String: String] = [:]
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            if shouldStop() {
                outcome[attribute] = "skipped at the deadline"
                continue
            }
            do throws(ReadError) {
                if try reader.bool(app, attribute) == true {
                    outcome[attribute] = "already true"
                    continue
                }
            } catch {
                if error == .unresponsive {
                    outcome[attribute] = "unresponsive"
                    break
                }
            }
            if shouldStop() {
                outcome[attribute] = "skipped at the deadline"
                continue
            }
            let error = AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
            outcome[attribute] = error == .success ? "set true" : "set failed \(error.rawValue)"
        }
        return outcome
    }

    /// Acts on one element from this probe's last scan. Bounded by a few AX IPCs plus at most one click.
    func perform(slot: Int) -> PerformReport {
        let s = slots[slot]
        let advertised = Set(reader.actionNames(s.element))
        let plan = ActionPlan.make(policy: config.clickPolicy, surface: s.surface, hitPoint: s.hitPoint, advertisedActions: advertised, content: s.content)
        let frontmostBefore = try? reader.bool(app, kAXFrontmostAttribute)

        var raised = false
        if plan.raiseWindow, let window = s.window {
            // Activation goes through AX, because cooperative activation (macOS 14 and later) lets an
            // inactive agent app's `activate` request for another app be ignored.
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            // Not for our own app: setting it in-process switched to another Space while our window showed over
            // a full-screen app (measured), and a window of ours that got a label is already in front of the user.
            if case .queue = lane {
                AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            raised = true
        }

        let act: PerformReport.Act
        switch plan.act {
        case .press(let fallback):
            let error = AXUIElementPerformAction(s.element, kAXPressAction as CFString)
            if ActionPlan.pressIsDone(axError: error.rawValue) {
                act = .pressed(error)
            } else {
                click(fallback, afterRaise: raised)
                act = .pressFailedThenClicked(error)
            }
        case .click(let point):
            click(point, afterRaise: raised)
            act = .clicked
        }

        return PerformReport(
            pid: pid, surface: s.surface, plan: plan, act: act,
            frontmostBefore: frontmostBefore, frontmostAfter: try? reader.bool(app, kAXFrontmostAttribute)
        )
    }

    /// Posts a left click through the HID tap, then puts the cursor back. Blocking waits are fine on another
    /// app's probe queue. On the main lane they stall the app, which happens only when one of our own
    /// elements has no `AXPress` or its press fails.
    private func click(_ point: GlobalPoint, afterRaise: Bool) {
        if afterRaise {
            let until = ContinuousClock.now + config.frontmostWait
            while ContinuousClock.now < until, (try? reader.bool(app, kAXFrontmostAttribute)) != true {
                usleep(10_000)
            }
        }
        let saved = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point.cgPoint, mouseButton: .left) else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            // Held modifiers would turn the click into a Command-click or a Shift-click.
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        guard let saved else { return }
        // The posted events move the cursor when the window server handles them, so a warp made right
        // away would be undone. Give them a moment first.
        usleep(30_000)
        CGWarpMouseCursorPosition(saved)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// Where a probe's AX calls run.
enum ProbeLane: Sendable {
    /// One of the eight queues. AX calls into another app are blocking Mach IPC.
    case queue(DispatchSerialQueue)
    /// Our own process. AX calls into it are not IPC: AppKit answers on the calling thread, and SwiftUI
    /// asserts the main queue (measured: a press from a global queue crashed in `dispatch_assert_queue`).
    case main
}

/// The fixed set of queues all AX work into other apps runs on. Bounds blocked threads to 8 however
/// many apps a scan touches (71 apps may own menu bar extras on the development machine).
/// Extras-only jobs cost one or two IPCs each and get their own two lanes, so they never queue behind
/// a window traversal that uses the whole budget. A hung app stalls its lane for one messaging timeout,
/// then its probe stops, so lane-mates still run within the budget.
enum ProbeQueues {
    static let light = (0..<2).map { DispatchSerialQueue(label: "everything-shortcut.ax.light.\($0)", qos: .userInitiated) }
    static let heavy = (0..<6).map { DispatchSerialQueue(label: "everything-shortcut.ax.heavy.\($0)", qos: .userInitiated) }

    static func assign(_ jobs: [AppScan], selfPID: PID) -> [(AppScan, ProbeLane)] {
        var lightIndex = 0
        var heavyIndex = 0
        return jobs.map { job in
            if job.pid == selfPID { return (job, .main) }
            if job.isExtrasOnly {
                defer { lightIndex += 1 }
                return (job, .queue(light[lightIndex % light.count]))
            }
            defer { heavyIndex += 1 }
            return (job, .queue(heavy[heavyIndex % heavy.count]))
        }
    }
}

private struct Root {
    let name: String
    let element: AXUIElement
    let clip: GlobalRect
    let surface: Surface
    let window: AXUIElement?
}

/// Everything `perform` needs about one element. Never leaves the probe.
private struct Slot {
    let element: AXUIElement
    /// The AX window to raise for `.window` surfaces.
    let window: AXUIElement?
    let surface: Surface
    let hitPoint: GlobalPoint
    let content: ElementContent
}

/// `ElementReader` over live AX. Constructed and used only inside `AppProbe`'s isolation.
private struct AXReader: ElementReader {
    /// Passed as a CFArray per call. Order is the parse order in `facts`.
    static let factAttributes: [String] = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute]

    /// One IPC. A missing position or size gives a nil frame, which the traversal treats as frameless.
    func facts(of element: AXUIElement) throws(ReadError) -> NodeFacts {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, Self.factAttributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard error == .success else { throw ReadError(error) }
        // With options 0, a missing attribute comes back as an AXValue of type .axError in its slot.
        guard let slots = values as? [AnyObject], slots.count == Self.factAttributes.count,
              let role = slots[0] as? String
        else { throw .unavailable }
        let frame: GlobalRect? = if let origin = Self.unpack(slots[1], .cgPoint, CGPoint.zero),
                                    let size = Self.unpack(slots[2], .cgSize, CGSize.zero) {
            GlobalRect(CGRect(origin: origin, size: size))
        } else {
            nil
        }
        return NodeFacts(role: role, frame: frame, isEnabled: slots[3] as? Bool ?? true)
    }

    /// One IPC for every source.
    func children(of element: AXUIElement, from source: ChildrenSource) throws(ReadError) -> [AXUIElement] {
        switch source {
        case .children:
            return try elements(element, kAXChildrenAttribute) ?? []
        case .visibleRows:
            return try elements(element, kAXVisibleRowsAttribute) ?? []
        case .searchPredicate(let keys):
            let query: [String: Any] = [
                "AXSearchKey": keys,
                "AXVisibleOnly": true,
                "AXDirection": "AXDirectionNext",
                "AXImmediateDescendantsOnly": false,
                "AXResultsLimit": -1,
            ]
            var out: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(element, "AXUIElementsForSearchPredicate" as CFString, query as CFDictionary, &out)
            switch error {
            case .success: return out as? [AXUIElement] ?? []
            case .noValue: return []
            case .cannotComplete: throw .unresponsive
            // Any other answer means this element cannot run the search, so the traversal reads children.
            default: throw .unsupported
            }
        }
    }

    func string(_ element: AXUIElement, _ attribute: String) throws(ReadError) -> String? {
        try copy(element, attribute) as? String
    }

    func bool(_ element: AXUIElement, _ attribute: String) throws(ReadError) -> Bool? {
        try copy(element, attribute) as? Bool
    }

    func element(_ element: AXUIElement, _ attribute: String) throws(ReadError) -> AXUIElement? {
        guard let value = try copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    func elements(_ element: AXUIElement, _ attribute: String) throws(ReadError) -> [AXUIElement]? {
        try copy(element, attribute) as? [AXUIElement]
    }

    /// Empty when the element advertises nothing or does not answer.
    func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// Nil for `.noValue`, which is an absent value and not a failure.
    private func copy(_ element: AXUIElement, _ attribute: String) throws(ReadError) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch error {
        case .success: return value
        case .noValue: return nil
        default: throw ReadError(error)
        }
    }

    private static func unpack<T: BitwiseCopyable>(_ object: AnyObject, _ type: AXValueType, _ initial: T) -> T? {
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(object, to: AXValue.self)
        guard AXValueGetType(value) == type else { return nil }
        var out = initial
        return AXValueGetValue(value, type, &out) ? out : nil
    }
}

extension ReadError {
    /// The classification itself is `ReadError.init(axError:)` in the core, where it is tested.
    init(_ error: AXError) {
        self.init(axError: error.rawValue)
    }
}

/// Private HIServices call used by yabai, AltTab and Rectangle to map an AX window to its CGWindowID.
/// The probe falls back to frame matching when it fails.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
