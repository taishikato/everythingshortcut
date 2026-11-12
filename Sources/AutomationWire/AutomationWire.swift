import Foundation

/// The DEBUG automation protocol between es-dev (untrusted shell) and the trusted app.
///
/// Requests travel over `DistributedNotificationCenter`, the JSON of an `AutomationRequest` under
/// `payloadKey`, posted with `deliverImmediately` because macOS suspends delivery to inactive apps.
/// The app writes each `AutomationReply` atomically to the request's `replyPath`, so the driver
/// never reads a half-written reply and needs no notification delivery in the other direction.
public enum AutomationChannel {
    public static let command = Notification.Name("com.taishikato.EverythingShortcut.automation.command")
    public static let payloadKey = "json"
    /// The app listens only when built DEBUG and launched with this argument.
    public static let launchArgument = "--automation"
}

/// One real input for the app to post through `CGEventPost(.cghidEventTap)`, so it travels the
/// same path as a physical one: Carbon hotkey matching, then the session event tap.
public enum AutomationInput: Codable, Hashable, Sendable {
    /// The trigger chord, with its modifier keys pressed and released around it.
    case trigger
    case escape
    case backspace
    /// Each character is mapped to a key code in the ASCII-capable layout and posted down then up.
    case letters(String)
    /// A left click at a point in global display space.
    case click(x: Double, y: Double)
    /// Any chord, posted like `trigger`. `modifiers` holds `HintCore.Modifiers` raw bits.
    case chord(keyCode: UInt16, modifiers: UInt8)
}

public enum AutomationCommand: Codable, Hashable, Sendable {
    /// Reply with the current snapshot. Does nothing else.
    case status
    /// Post the inputs in order, then reply with the snapshot taken right after posting.
    case press([AutomationInput])
    /// Apply these settings through the reducer without persisting them. Rejected, not defaulted, when invalid.
    case configure(triggerKeyCode: UInt16, triggerModifiers: UInt8)
    /// Open the app window. Nothing closes it again: closing stores setup completion,
    /// and a run must not write the user's settings, so the script's pkill ends it.
    case openWindow
}

public struct AutomationRequest: Codable, Hashable, Sendable {
    public let id: String
    public let command: AutomationCommand
    public let replyPath: String

    public init(id: String, command: AutomationCommand, replyPath: String) {
        self.id = id
        self.command = command
        self.replyPath = replyPath
    }
}

public struct AutomationReply: Codable, Hashable, Sendable {
    public let id: String
    /// Set when the request could not be carried out, for example a letter with no key code.
    public let error: String?
    public let snapshot: SessionSnapshot

    public init(id: String, error: String?, snapshot: SessionSnapshot) {
        self.id = id
        self.error = error
        self.snapshot = snapshot
    }
}

public struct RectDump: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct HintDump: Codable, Hashable, Sendable {
    public let label: String
    public let pid: Int32
    /// "window:<id>", "menuBar", "statusItem" or "dock".
    public let surface: String
    /// Visible frame in global display space (top-left origin).
    public let frame: RectDump

    public init(label: String, pid: Int32, surface: String, frame: RectDump) {
        self.label = label
        self.pid = pid
        self.surface = surface
        self.frame = frame
    }
}

/// One app's part of the last scan.
public struct AppScanDump: Codable, Hashable, Sendable {
    public let pid: Int32
    /// The job read only `AXExtrasMenuBar`, on a light lane.
    public let extrasOnly: Bool
    /// "menuBar", "window:<id>", "statusItems" and "dock", in walk order.
    public let roots: [String]
    public let durationMs: Double
    public let nodesRead: Int
    /// "budget", "unresponsive" or "nodeLimit". Nil when every root was walked to the end.
    public let stop: String?
    /// Candidates before occlusion and deduplication.
    public let candidates: Int
    /// The raw search result count of each web area. Every job but an extras-only one reads the app's `AXRole` first.
    public let webAreaResults: [Int]
    /// Attribute name to what the probe found and did, for `AXEnhancedUserInterface` and `AXManualAccessibility`.
    public let webFlags: [String: String]

    public init(pid: Int32, extrasOnly: Bool, roots: [String], durationMs: Double, nodesRead: Int, stop: String?, candidates: Int, webAreaResults: [Int], webFlags: [String: String]) {
        self.pid = pid
        self.extrasOnly = extrasOnly
        self.roots = roots
        self.durationMs = durationMs
        self.nodesRead = nodesRead
        self.stop = stop
        self.candidates = candidates
        self.webAreaResults = webAreaResults
        self.webFlags = webFlags
    }

    /// An extras-only job that the budget ended before its one `AXExtrasMenuBar` read.
    /// Extras-only jobs share two lanes, and each app that does not answer holds its lane for one
    /// messaging timeout, so with many such apps the jobs at the back of a lane never get their turn.
    /// How many apps do not answer depends on what is running, not on the scan.
    public var wasStarved: Bool { extrasOnly && stop == "budget" && roots.isEmpty }

    /// The scan lost part of this app: a walk hit the node limit, or the budget ended a job that had
    /// started, or one that was to walk a window, a menu bar or the Dock.
    public var wasCutShort: Bool { stop == "nodeLimit" || (stop == "budget" && !wasStarved) }
}

/// A menu bar extra dropped because another app exposed one with the same frame.
public struct StatusItemDuplicateDump: Codable, Hashable, Sendable {
    public let frame: RectDump
    public let keptPid: Int32
    public let droppedPid: Int32

    public init(frame: RectDump, keptPid: Int32, droppedPid: Int32) {
        self.frame = frame
        self.keptPid = keptPid
        self.droppedPid = droppedPid
    }
}

public struct ScanDump: Codable, Hashable, Sendable {
    public let durationMs: Double
    public let nodesRead: Int
    public let candidatesBeforeOcclusion: Int
    public let candidates: Int
    public let apps: [AppScanDump]
    public let droppedStatusItems: [StatusItemDuplicateDump]

    public init(durationMs: Double, nodesRead: Int, candidatesBeforeOcclusion: Int, candidates: Int, apps: [AppScanDump], droppedStatusItems: [StatusItemDuplicateDump]) {
        self.durationMs = durationMs
        self.nodesRead = nodesRead
        self.candidatesBeforeOcclusion = candidatesBeforeOcclusion
        self.candidates = candidates
        self.apps = apps
        self.droppedStatusItems = droppedStatusItems
    }
}

public struct PerformDump: Codable, Hashable, Sendable {
    public let pid: Int32
    public let surface: String
    /// The action plan, for example "raise, press" or "click".
    public let plan: String
    /// What ran, for example "press: success", "press: error -25204, then click" or "click".
    public let act: String
    public let frontmostBefore: Bool?
    public let frontmostAfter: Bool?

    public init(pid: Int32, surface: String, plan: String, act: String, frontmostBefore: Bool?, frontmostAfter: Bool?) {
        self.pid = pid
        self.surface = surface
        self.plan = plan
        self.act = act
        self.frontmostBefore = frontmostBefore
        self.frontmostAfter = frontmostAfter
    }
}

/// A chord as raw wire values. `modifiers` holds `HintCore.Modifiers` raw bits.
public struct TriggerDump: Codable, Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: UInt8

    public init(keyCode: UInt16, modifiers: UInt8) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct SessionSnapshot: Codable, Hashable, Sendable {
    /// "idle", "scanning", "showing" or "performing".
    public let phase: String
    public let typed: String
    /// Hints still matching `typed`. Empty unless showing.
    public let hints: [HintDump]
    /// Frames of the overlay panels currently ordered in, in AppKit coordinates.
    public let overlayPanels: [RectDump]
    public let accessibilityTrusted: Bool
    public let triggerRegistered: Bool
    /// The applied trigger. A configure sent mid-session shows here once the session ends.
    public let trigger: TriggerDump
    public let lastScan: ScanDump?
    public let lastPerform: PerformDump?
    /// The app window in global display space. Nil while it is not on screen.
    public let appWindow: RectDump?

    public init(phase: String, typed: String, hints: [HintDump], overlayPanels: [RectDump], accessibilityTrusted: Bool, triggerRegistered: Bool, trigger: TriggerDump, lastScan: ScanDump?, lastPerform: PerformDump?, appWindow: RectDump?) {
        self.phase = phase
        self.typed = typed
        self.hints = hints
        self.overlayPanels = overlayPanels
        self.accessibilityTrusted = accessibilityTrusted
        self.triggerRegistered = triggerRegistered
        self.trigger = trigger
        self.lastScan = lastScan
        self.lastPerform = lastPerform
        self.appWindow = appWindow
    }
}
