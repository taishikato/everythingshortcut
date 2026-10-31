/// The rows of the app window's checklist, in order.
public enum SetupStep: Hashable, Sendable, CaseIterable {
    case access
    case shortcut
}

/// What the shell reads from macOS on each refresh.
public struct SetupFacts: Hashable, Sendable {
    public var trusted: Bool
    /// Registered, and no enabled macOS shortcut takes it first.
    /// A chord another app holds exclusively still reads true, because nothing can see it.
    public var shortcutWorks: Bool

    public init(trusted: Bool, shortcutWorks: Bool) {
        self.trusted = trusted
        self.shortcutWorks = shortcutWorks
    }
}

/// What Return does in the window. The view puts `.defaultAction` on exactly this control.
public enum SetupAction: Hashable, Sendable {
    case openSystemSettings
    case recordShortcut
    case finish
}

public enum SetupEvent: Hashable, Sendable {
    case refreshed(SetupFacts)
    /// The Accessibility button ran: the system prompt or the pane is up.
    case askedForAccess
    /// Skip Setup, Done, Command-W or the close button: the window closed.
    case dismissed
}

public enum SetupEffect: Hashable, Sendable {
    /// Store that setup is complete. Emitted at most once per guide.
    case persistComplete
    /// Put the window in front of the app the user is in. Activation is only requested.
    case comeForward
}

/// The app window's checklist: Accessibility and the shortcut.
/// The single owner is the `SettingsModel` that holds this value.
///
/// Transition table (anything not listed changes nothing and returns []):
///
///     any  refreshed(f)                facts = f
///            and trusted false -> true                      [comeForward]
///     any  askedForAccess              accessAsked = true
///     any  dismissed, not complete     isComplete = true, accessAsked = false  [persistComplete]
///     any  dismissed, complete         accessAsked = false
public struct SetupGuide: Hashable, Sendable {
    public private(set) var facts: SetupFacts
    /// Mirrors the stored flag. Written only through `persistComplete`.
    public private(set) var isComplete: Bool
    public private(set) var accessAsked = false

    public init(facts: SetupFacts, isComplete: Bool) {
        self.facts = facts
        self.isComplete = isComplete
    }

    public mutating func send(_ event: SetupEvent) -> [SetupEffect] {
        switch event {
        case .refreshed(let next):
            let granted = !facts.trusted && next.trusted
            facts = next
            return granted ? [.comeForward] : []

        case .askedForAccess:
            accessAsked = true
            return []

        case .dismissed:
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
        }
    }

    /// The first step that is not done. The window marks it and points Return at its action.
    public var current: SetupStep? {
        SetupStep.allCases.first { !isDone($0) }
    }

    /// Done exists only during first-run setup, so a complete guide with nothing left has no action.
    public var returnAction: SetupAction? {
        switch current {
        case .access: .openSystemSettings
        case .shortcut: .recordShortcut
        case nil: isComplete ? nil : .finish
        }
    }

    /// The window opens by itself at launch until setup was finished or skipped once, and after that
    /// only when Accessibility is missing, so a login launch never nags about the shortcut.
    public var opensAtLaunch: Bool { !isComplete || !facts.trusted }
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
