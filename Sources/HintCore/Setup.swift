/// The rows of the app window's checklist, in order.
public enum SetupStep: Hashable, Sendable, CaseIterable {
    case access
    case shortcut
    case practice
}

/// What the shell reads from macOS on each refresh. The window keeps no other copy of these facts.
public struct SetupFacts: Hashable, Sendable {
    public var trusted: Bool
    /// Registered, and no enabled macOS shortcut takes it first.
    /// A chord another app holds exclusively still reads true (docs/design.md), which is why the practice exists.
    public var shortcutWorks: Bool
    /// The applied trigger. A change reopens the practice, so the new chord gets tried.
    public var trigger: HotKey

    public init(trusted: Bool, shortcutWorks: Bool, trigger: HotKey) {
        self.trusted = trusted
        self.shortcutWorks = shortcutWorks
        self.trigger = trigger
    }
}

/// What the app window learns about hint sessions. `HintController` derives one per drained event.
public enum SessionNote: Hashable, Sendable {
    case started
    /// Back to idle. `performed` is true when a label was typed to the end and its element acted.
    case ended(performed: Bool)
    /// A trigger at idle that the gate refused.
    case blocked(Alert)

    /// The meaning of one reducer step to the app window. Nil when the step changes nothing it shows.
    ///
    ///     idle               -> idle, event trigger(blocked a)   blocked(a)
    ///     idle               -> scanning                         started
    ///     performing         -> idle                             ended(performed: true)
    ///     scanning | showing -> idle                             ended(performed: false)
    ///     anything else                                          nil
    ///
    /// `Phase` is Equatable only for an Equatable `Target`, so this matches cases and never compares boards.
    public static func of<Target>(_ event: Event<Target>, from before: Phase<Target>, to after: Phase<Target>) -> SessionNote? {
        switch (before, after) {
        case (.idle, .idle):
            if case .trigger(.blocked(let alert)) = event { return .blocked(alert) }
            return nil
        case (.idle, .scanning):
            return .started
        case (.performing, .idle):
            return .ended(performed: true)
        case (.scanning, .idle), (.showing, .idle):
            return .ended(performed: false)
        default:
            return nil
        }
    }
}

/// The hands-on step. Its states differ in what the status line under the target says.
public enum Practice: Hashable, Sendable {
    /// Nobody asked for it. After setup is complete the row is hidden until Try It or a new trigger.
    case idle
    /// Waiting for the trigger.
    case ready
    /// Labels are on screen. Drawn exactly like `ready`, so nothing under the labels moves.
    case labelsOpen
    case missed(Miss)
    /// The trigger was refused because Secure Event Input is on.
    case secureInput
    case succeeded
}

public enum Miss: Hashable, Sendable {
    /// Escape, the trigger again, a mouse-down, lost key capture, or no labels at all.
    case closed
    /// A label was typed to the end, but it was not the target's.
    case elsewhere
    /// The target's action ran while no label was being acted on: the mouse, or Space on a focused button.
    case withoutLabel
}

/// What Return does in the window. The view puts `.defaultAction` on exactly this control.
public enum SetupAction: Hashable, Sendable {
    case openSystemSettings
    case recordShortcut
    case finish
}

/// How the practice row is drawn. Nil from `SetupGuide.practiceRow` means no row at all.
public enum PracticeRow: Hashable, Sendable {
    /// An earlier step is not done, so the trigger cannot work yet.
    case locked
    case open(Practice)
}

public enum SetupEvent: Hashable, Sendable {
    case refreshed(SetupFacts)
    /// The Accessibility button ran: the system prompt or the pane is up.
    case askedForAccess
    case session(SessionNote)
    /// The target's action ran. `viaLabel` is whether the controller was performing a label at that moment.
    case targetPressed(viaLabel: Bool)
    /// Try It, from the shortcut row once setup is complete.
    case tryAgain
    /// Skip Setup, Done, Command-W or the close button: the window closed.
    case dismissed
}

public enum SetupEffect: Hashable, Sendable {
    /// Store that setup is complete. Emitted at most once per guide.
    case persistComplete
    /// Put the window in front of the app the user is in. Activation is only requested.
    case comeForward
}

/// The app window's checklist: Accessibility, the shortcut, and a hands-on try.
/// The single owner is the `SettingsModel` that holds this value.
///
/// Transition table (anything not listed changes nothing and returns []):
///
///     any         refreshed(f)                        facts = f
///                   and trusted false -> true                                   [comeForward]
///                   and f.trigger != facts.trigger    practice = ready
///     any         askedForAccess                      accessAsked = true
///     ready | missed | secureInput
///                 session(started)                    practice = labelsOpen
///     labelsOpen  session(ended(performed: true))     practice = missed(elsewhere)
///     labelsOpen  session(ended(performed: false))    practice = missed(closed)
///     ready | missed | secureInput
///                 session(blocked(secureInputActive)) practice = secureInput
///     ready | labelsOpen | missed | secureInput
///                 targetPressed(viaLabel: true)       practice = succeeded
///     ready | missed | secureInput
///                 targetPressed(viaLabel: false)      practice = missed(withoutLabel)
///     any         tryAgain                            practice = ready
///     any         dismissed, not complete             isComplete = true, practice = idle,
///                                                     accessAsked = false              [persistComplete]
///     any         dismissed, complete                 practice = idle, accessAsked = false
///
/// Ignored on purpose:
///
///     idle | succeeded  session(*), targetPressed(*)  nobody asked, or the user already made it
///     any               session(blocked(needsAccessibility))  the shell opens the window and refreshes
///     ready | missed | secureInput  session(ended(*)) a session that began before the practice did
///     labelsOpen        targetPressed(viaLabel: false) a mouse-down ends the session first
///
/// `targetPressed(viaLabel: true)` arrives before `session(ended(performed: true))`, because our own
/// probe presses on the main thread and SwiftUI runs the action inside the press.
public struct SetupGuide: Hashable, Sendable {
    public private(set) var facts: SetupFacts
    /// Mirrors the stored flag. Written only through `persistComplete`.
    public private(set) var isComplete: Bool
    public private(set) var accessAsked = false
    public private(set) var practice: Practice

    public init(facts: SetupFacts, isComplete: Bool) {
        self.facts = facts
        self.isComplete = isComplete
        practice = isComplete ? .idle : .ready
    }

    public mutating func send(_ event: SetupEvent) -> [SetupEffect] {
        switch event {
        case .refreshed(let next):
            let granted = !facts.trusted && next.trusted
            if next.trigger != facts.trigger { practice = .ready }
            facts = next
            return granted ? [.comeForward] : []

        case .askedForAccess:
            accessAsked = true
            return []

        case .session(let note):
            practice = practice.after(note)
            return []

        case .targetPressed(let viaLabel):
            practice = practice.afterPress(viaLabel: viaLabel)
            return []

        case .tryAgain:
            practice = .ready
            return []

        case .dismissed:
            practice = .idle
            accessAsked = false
            guard !isComplete else { return [] }
            isComplete = true
            return [.persistComplete]
        }
    }

    public func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .access: facts.trusted
        case .shortcut: facts.shortcutWorks
        case .practice: practice == .idle || practice == .succeeded
        }
    }

    /// The first step that is not done. The window marks it and points Return at its action.
    public var current: SetupStep? {
        SetupStep.allCases.first { !isDone($0) }
    }

    /// Nil while the practice is idle. Locked while Accessibility or the shortcut is not done,
    /// except after a success, which stays readable even if a fact regressed.
    public var practiceRow: PracticeRow? {
        switch practice {
        case .idle: nil
        case .succeeded: .open(.succeeded)
        default: current == .practice ? .open(practice) : .locked
        }
    }

    /// The practice itself is done with the trigger, not with Return, so it has no action.
    public var returnAction: SetupAction? {
        switch current {
        case .access: .openSystemSettings
        case .shortcut: .recordShortcut
        case .practice, nil: !isComplete && practice == .succeeded ? .finish : nil
        }
    }

    /// The window opens by itself at launch until setup was finished or skipped once, and after that
    /// only when Accessibility is missing, so a login launch never nags about the shortcut.
    public var opensAtLaunch: Bool { !isComplete || !facts.trusted }
}

extension Practice {
    fileprivate func after(_ note: SessionNote) -> Practice {
        switch (self, note) {
        case (.ready, .started), (.missed, .started), (.secureInput, .started):
            .labelsOpen
        case (.labelsOpen, .ended(let performed)):
            .missed(performed ? .elsewhere : .closed)
        case (.ready, .blocked(.secureInputActive)), (.missed, .blocked(.secureInputActive)), (.secureInput, .blocked(.secureInputActive)):
            .secureInput
        default:
            self
        }
    }

    fileprivate func afterPress(viaLabel: Bool) -> Practice {
        switch (self, viaLabel) {
        case (.ready, true), (.labelsOpen, true), (.missed, true), (.secureInput, true):
            .succeeded
        case (.ready, false), (.missed, false), (.secureInput, false):
            .missed(.withoutLabel)
        default:
            self
        }
    }
}

/// Whether the user can see the status item in the menu bar.
public enum MenuBarIcon: Hashable, Sendable {
    case visible
    case hidden

    /// Hidden when there is no item window, when the window reports it is not visible, or when the item
    /// overlaps the notch gap of its screen (measured: x 721 w 38 against the gap 663..<848, with the item
    /// window's `isVisible` still true). x is the same in AppKit and global display space.
    /// No visible item has been measured, so every doubt reads hidden, whose copy is right in both cases.
    public static func judge(itemMinX: Double?, itemWidth: Double, notchGap: Range<Double>?, windowVisible: Bool) -> MenuBarIcon {
        guard let itemMinX, itemWidth > 0, windowVisible else { return .hidden }
        if let notchGap, notchGap.overlaps(itemMinX..<(itemMinX + itemWidth)) { return .hidden }
        return .visible
    }
}
