/// How a chosen element gets "clicked". Set once in `HintConfig.standard`.
/// The policy chooses press versus click only. Whether to raise the window first depends on the surface.
public enum ClickPolicy: Hashable, Sendable {
    /// `AXPress` when a native element advertises it, otherwise a synthesized left click.
    /// AXPress fires on the first attempt even in an inactive window and never moves the cursor.
    /// Web content is always clicked: Chrome answers `AXPress` on web elements with `kAXErrorSuccess`
    /// and performs nothing, so a successful press says nothing about whether the link was activated.
    case pressWhenAdvertised
    /// Always a synthesized left click at the hit point, as Vimac does. Unlike Vimac, `.window` surfaces still raise first.
    case alwaysClick
}

/// The concrete steps for one chosen element. Executed by the element's probe actor.
/// The act is `.press` only for `.pressWhenAdvertised` on `.native` content that advertises `AXPress`.
/// `.web` content gets `.click`, because Chrome reports success for `AXPress` on web elements without acting.
public struct ActionPlan: Hashable, Sendable {
    public enum Act: Hashable, Sendable {
        /// `AXPress`. `pressIsDone(axError:)` decides whether the press counts as done.
        /// When it does not, the probe clicks `fallback` instead.
        case press(fallback: GlobalPoint)
        /// Synthesized mouseDown/mouseUp at the point via the HID tap, then the cursor is restored.
        case click(GlobalPoint)
    }

    /// Bring the element's window and app to the front before acting, as a real click would.
    /// Raising first means a fallback click lands on an active window instead of only activating it.
    public let raiseWindow: Bool
    public let act: Act

    public static func make(
        policy: ClickPolicy,
        surface: Surface,
        hitPoint: GlobalPoint,
        advertisedActions: Set<String>,
        content: ElementContent
    ) -> ActionPlan {
        let raise: Bool
        switch surface {
        case .window: raise = true
        case .menuBar, .statusItem, .dock: raise = false
        }
        switch (policy, content) {
        case (.pressWhenAdvertised, .native) where advertisedActions.contains("AXPress"):
            return ActionPlan(raiseWindow: raise, act: .press(fallback: hitPoint))
        case (.pressWhenAdvertised, _), (.alwaysClick, _):
            return ActionPlan(raiseWindow: raise, act: .click(hitPoint))
        }
    }
}
