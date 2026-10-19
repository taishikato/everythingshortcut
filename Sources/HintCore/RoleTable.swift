/// Where a container's children come from. Each case is one AX IPC.
public enum ChildrenSource: Hashable, Sendable {
    /// `AXChildren`.
    case children
    /// `AXVisibleRows`. Tables and outlines return only on-screen rows instead of every row.
    case visibleRows
    /// `AXUIElementsForSearchPredicate` with `AXVisibleOnly`, matching any of `keys`.
    /// One IPC returns every visible interactive descendant of a web area.
    /// The results are terminal and never descended into. Each one is a candidate only if its own
    /// role's rule is `.hint`, so the table decides hintability for web content too.
    /// If the element does not support the parameterized attribute, traversal falls back to `.children`.
    case searchPredicate(keys: [String])
}

/// What the traversal does with a node of a given role.
public enum RoleRule: Hashable, Sendable {
    /// A candidate when enabled and visible. Its children are never read.
    case hint
    /// Not a candidate. Read children from `source` and visit them.
    /// When `clips` is true, children are clipped to this node's visible frame.
    case container(ChildrenSource, clips: Bool)
    /// Neither a candidate nor visited further.
    case skip
}

/// The single source of truth for which elements get hints and how the tree is walked.
///
/// Hintability is decided by role alone. The scan never calls `AXUIElementCopyActionNames`,
/// which would double the IPC count per node. Action names are read once, for the chosen
/// element only, by the action planner. See docs/design.md, "Hintable-role table".
///
/// Adding a role is one line in `standard`. Flipping a role between hint and container is one word.
public struct RoleTable: Sendable {
    public let rules: [String: RoleRule]
    /// Rule for roles missing from `rules`, including AXGroup and unknown custom roles.
    public let fallback: RoleRule

    public init(rules: [String: RoleRule], fallback: RoleRule) {
        self.rules = rules
        self.fallback = fallback
    }

    public func rule(for role: String) -> RoleRule { rules[role] ?? fallback }

    public static let webSearchKeys = [
        "AXButtonSearchKey",
        "AXCheckBoxSearchKey",
        "AXControlSearchKey",
        "AXLinkSearchKey",
        "AXTextFieldSearchKey",
    ]

    public static let standard = RoleTable(
        rules: [
            // Candidates.
            "AXButton": .hint,
            "AXCheckBox": .hint,
            "AXRadioButton": .hint,
            "AXPopUpButton": .hint,
            "AXMenuButton": .hint,
            "AXMenuBarItem": .hint,
            "AXLink": .hint,
            "AXDockItem": .hint,
            "AXDisclosureTriangle": .hint,
            "AXIncrementor": .hint,
            "AXColorWell": .hint,
            "AXTextField": .hint,
            "AXTextArea": .hint,
            "AXComboBox": .hint,
            "AXRow": .hint,

            // Containers that clip their children to their own visible frame.
            "AXWindow": .container(.children, clips: true),
            "AXSheet": .container(.children, clips: true),
            "AXPopover": .container(.children, clips: true),
            "AXScrollArea": .container(.children, clips: true),

            // Containers with a cheaper child source.
            "AXTable": .container(.visibleRows, clips: false),
            "AXOutline": .container(.visibleRows, clips: false),
            "AXWebArea": .container(.searchPredicate(keys: webSearchKeys), clips: false),

            // Never candidates, never descended.
            "AXStaticText": .skip,
            "AXImage": .skip,
            "AXScrollBar": .skip,
            "AXValueIndicator": .skip,
            "AXSlider": .skip,
            "AXSplitter": .skip,
            "AXRuler": .skip,
            "AXRulerMarker": .skip,
            "AXGrowArea": .skip,
            "AXBusyIndicator": .skip,
            "AXProgressIndicator": .skip,
            "AXLevelIndicator": .skip,
            "AXRelevanceIndicator": .skip,
            "AXHelpTag": .skip,
            "AXMenu": .skip,
            "AXMatte": .skip,
        ],
        fallback: .container(.children, clips: false)
    )
}
