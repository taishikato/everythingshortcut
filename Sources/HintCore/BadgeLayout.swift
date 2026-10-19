/// One badge as drawn: uppercase text, how many leading characters are already typed,
/// and its top-left corner in its display's local, y-down space.
public struct Badge: Hashable, Sendable {
    public let text: String
    public let typedCount: Int
    public let origin: LocalPoint
}

/// The badges for one display. The overlay keeps one panel per entry and no others.
public struct DisplayBadges: Hashable, Sendable {
    public let display: Display
    public let badges: [Badge]
}

public enum BadgeLayout {
    /// Pure projection of a board onto displays. The overlay renders the result and holds no other state.
    /// Hints that no longer match `typed` disappear. A badge goes to the display containing its anchor,
    /// else the display containing its hit point. Displays with no badges are omitted.
    public static func layout<Target>(_ board: Board<Target>, displays: [Display]) -> [DisplayBadges] {
        var byDisplay: [DisplayID: [Badge]] = [:]
        for hint in board.matching {
            let c = hint.candidate
            guard let display = displays.containing(c.anchor) ?? displays.containing(c.hitPoint) else { continue }
            byDisplay[display.id, default: []].append(
                Badge(text: hint.label.uppercased(), typedCount: board.typed.count, origin: display.local(c.anchor))
            )
        }
        return displays.compactMap { d in byDisplay[d.id].map { DisplayBadges(display: d, badges: $0) } }
    }
}
