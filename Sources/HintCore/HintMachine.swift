/// One clickable element found by a scan, before labeling.
/// `Target` is the shell's handle for acting on the element later. The core never inspects it.
public struct Candidate<Target: Sendable>: Sendable {
    public let target: Target
    public let pid: PID
    public let surface: Surface
    /// Visible frame: the element frame clipped by its window and scroll areas.
    public let frame: GlobalRect

    public init(target: Target, pid: PID, surface: Surface, frame: GlobalRect) {
        self.target = target
        self.pid = pid
        self.surface = surface
        self.frame = frame
    }

    /// Where occlusion is tested and where a synthesized click lands.
    public var hitPoint: GlobalPoint { frame.center }
    /// Where the badge's top-left corner goes, as in Vimium.
    public var anchor: GlobalPoint { frame.origin }
}

public struct Hint<Target: Sendable>: Sendable {
    public let label: String
    public let candidate: Candidate<Target>
}

/// The hints on screen and what has been typed so far.
/// Invariant: `typed` is a prefix of at least one label, or empty.
public struct Board<Target: Sendable>: Sendable {
    public let hints: [Hint<Target>]
    public fileprivate(set) var typed: String = ""

    public var matching: [Hint<Target>] { hints.filter { $0.label.hasPrefix(typed) } }
}

public struct ScanID: Hashable, Sendable {
    public let raw: UInt64
}

public enum Phase<Target: Sendable>: Sendable {
    case idle
    /// Waiting for the scan with this id. Results with any other id are stale and dropped.
    case scanning(ScanID)
    case showing(Board<Target>)
    /// The chosen element is being acted on. Keys already flow to apps again.
    case performing(Target)
}

public enum Alert: Hashable, Sendable {
    case needsAccessibility
    /// Secure Event Input (a focused password field) blinds the event tap, so typed labels
    /// would reach the password field. Refuse to start instead.
    case secureInputActive
    case noHints
    case noMatch
    case keyCaptureLost
}

/// Facts the shell checks on a trigger press. The reducer decides what they mean.
public enum TriggerGate: Hashable, Sendable {
    case ready
    case blocked(Alert)
}

public enum Event<Target: Sendable>: Sendable {
    /// The Carbon hotkey fired. The only source of trigger presses (see `KeyRouting.route`).
    case trigger(TriggerGate)
    case scanned(ScanID, [Candidate<Target>])
    case key(KeyInput)
    /// A mouse button went down anywhere. The click itself passes through to its target.
    case mouseDown
    /// The action finished, succeeded or not.
    case performed
    /// The event tap could not be created or re-enabled.
    case keyCaptureLost
    /// The user chose new settings. They apply at once when idle, otherwise when the session ends.
    case configure(UserSettings)
}

/// Commands for the shell. The shell runs them in order and never decides policy.
public enum Effect<Target: Sendable>: Sendable {
    case startScan(ScanID)
    case cancelScan
    /// Enable or disable the keyboard event tap. Idempotent in the shell.
    case captureKeys(Bool)
    /// Draw exactly this board, or nothing. Declarative, so a repeat is harmless.
    case render(Board<Target>?)
    case perform(Target)
    case alert(Alert)
    /// Register the trigger and retune key capture for these settings. Only ever emitted at idle.
    case applySettings(UserSettings)
}

/// The hint session. The single owner of session state is the `HintController` that holds this value.
///
/// Transition table (anything not listed is a no-op):
///
///     idle        trigger(ready)     -> scanning(new id)  [captureKeys(true), startScan]
///     idle        trigger(blocked a) -> idle              [alert(a)]
///     scanning    trigger | escape | mouseDown -> idle    [cancelScan, captureKeys(false)]
///     scanning(i) scanned(i, [])     -> idle              [captureKeys(false), alert(noHints)]
///     scanning(i) scanned(i, cs)     -> showing           [render(board)]
///     showing     trigger | escape | mouseDown -> idle    [render(nil), captureKeys(false)]
///     showing     backspace          -> showing           [render(board)]       (no-op when typed is empty)
///     showing     letter, no match   -> showing           [alert(noMatch)]      (typed unchanged)
///     showing     letter, exact      -> performing(t)     [render(nil), captureKeys(false), perform(t)]
///     showing     letter, prefix     -> showing           [render(board)]
///     performing  performed          -> idle              []
///     scanning|showing keyCaptureLost -> idle             [cancelScan?, render(nil)?, captureKeys(false), alert]
///     idle        configure(s)       -> idle              [applySettings(s)]
///     other       configure(s)       -> unchanged         []                    (s waits as pending, the last one wins)
///     any row that lands in idle with s pending           [..., applySettings(s)]  (labels of later scans use s)
///
/// Settings never change mid-session, so the trigger that ends a session is the one that started it,
/// and the tap's alphabet always matches the labels on screen.
/// Scan ids make stale results harmless. A cancelled scan's `scanned` event matches no state.
/// A trigger or mouse-down while performing is ignored, so our own synthesized click cannot end it.
/// Performing lasts one AX call plus at most one click.
public struct HintMachine<Target: Sendable>: Sendable {
    public private(set) var phase: Phase<Target> = .idle
    public private(set) var settings: UserSettings
    /// Invariant: nil whenever `phase` is idle.
    private var pending: UserSettings?
    private var scansStarted: UInt64 = 0

    public init(settings: UserSettings) { self.settings = settings }

    public mutating func send(_ event: Event<Target>) -> [Effect<Target>] {
        var effects = transition(event)
        if case .idle = phase, let next = pending {
            pending = nil
            settings = next
            effects.append(.applySettings(next))
        }
        return effects
    }

    private mutating func transition(_ event: Event<Target>) -> [Effect<Target>] {
        switch (phase, event) {
        case (.idle, .configure(let next)):
            settings = next
            return [.applySettings(next)]

        case (_, .configure(let next)):
            pending = next
            return []

        case (.idle, .trigger(.ready)):
            scansStarted += 1
            let id = ScanID(raw: scansStarted)
            phase = .scanning(id)
            return [.captureKeys(true), .startScan(id)]

        case (.idle, .trigger(.blocked(let alert))):
            return [.alert(alert)]

        case (.scanning, .trigger), (.scanning, .key(.escape)), (.scanning, .mouseDown):
            phase = .idle
            return [.cancelScan, .captureKeys(false)]

        case (.scanning(let current), .scanned(let id, let candidates)) where id == current:
            guard !candidates.isEmpty else {
                phase = .idle
                return [.captureKeys(false), .alert(.noHints)]
            }
            let board = Board(hints: Self.label(candidates, alphabet: settings.alphabet))
            phase = .showing(board)
            return [.render(board)]

        case (.showing, .trigger), (.showing, .key(.escape)), (.showing, .mouseDown):
            phase = .idle
            return [.render(nil), .captureKeys(false)]

        case (.showing(var board), .key(.backspace)):
            guard !board.typed.isEmpty else { return [] }
            board.typed.removeLast()
            phase = .showing(board)
            return [.render(board)]

        case (.showing(var board), .key(.letter(let c))):
            let typed = board.typed + String(c)
            let matches = board.hints.filter { $0.label.hasPrefix(typed) }
            if matches.isEmpty { return [.alert(.noMatch)] }
            if matches.count == 1, matches[0].label == typed {
                let target = matches[0].candidate.target
                phase = .performing(target)
                return [.render(nil), .captureKeys(false), .perform(target)]
            }
            board.typed = typed
            phase = .showing(board)
            return [.render(board)]

        case (.performing, .performed):
            phase = .idle
            return []

        case (.scanning, .keyCaptureLost):
            phase = .idle
            return [.cancelScan, .captureKeys(false), .alert(.keyCaptureLost)]

        case (.showing, .keyCaptureLost):
            phase = .idle
            return [.render(nil), .captureKeys(false), .alert(.keyCaptureLost)]

        default:
            return []
        }
    }

    /// Reading order (top to bottom, then left to right) gets labels shortest first,
    /// so the menu bar and toolbars get the single-letter labels.
    static func label(_ candidates: [Candidate<Target>], alphabet: Alphabet) -> [Hint<Target>] {
        let ordered = candidates.sorted { a, b in
            a.anchor.y != b.anchor.y ? a.anchor.y < b.anchor.y : a.anchor.x < b.anchor.x
        }
        let labels = LabelGenerator.labels(count: ordered.count, alphabet: alphabet)
        return zip(labels, ordered).map { Hint(label: $0, candidate: $1) }
    }
}

extension Candidate: Equatable where Target: Equatable {}
extension Hint: Equatable where Target: Equatable {}
extension Board: Equatable where Target: Equatable {}
extension Phase: Equatable where Target: Equatable {}
extension Event: Equatable where Target: Equatable {}
extension Effect: Equatable where Target: Equatable {}
