/// The facts the traversal needs about one node, read in one batched IPC
/// (`AXUIElementCopyMultipleAttributeValues` over role, position, size, enabled).
public struct NodeFacts: Hashable, Sendable {
    public var role: String
    /// Nil when the element reports no position or size.
    public var frame: GlobalRect?
    /// Elements that do not report `AXEnabled` count as enabled.
    public var isEnabled: Bool

    public init(role: String, frame: GlobalRect?, isEnabled: Bool = true) {
        self.role = role
        self.frame = frame
        self.isEnabled = isEnabled
    }
}

/// AX failures, already classified by the reader at the AX boundary.
public enum ReadError: Error, Hashable, Sendable {
    /// The app did not answer within the messaging timeout (`kAXErrorCannotComplete`).
    /// The traversal stops for this app: every further call would cost another timeout.
    case unresponsive
    /// The element vanished or has no value (`kAXErrorInvalidUIElement`, `kAXErrorNoValue`, ...).
    /// The node is skipped.
    case unavailable
    /// The attribute or parameterized attribute is unsupported on this element.
    case unsupported
}

/// One app's AX tree, seen through the two calls the traversal makes.
/// The AX implementation lives in the shell and is confined to the app's probe actor.
/// Tests implement it over an in-memory tree.
public protocol ElementReader {
    associatedtype Element
    func facts(of element: Element) throws(ReadError) -> NodeFacts
    func children(of element: Element, from source: ChildrenSource) throws(ReadError) -> [Element]
}

public enum StopReason: Hashable, Sendable {
    case budget
    case unresponsive
    case nodeLimit
}

/// Whether an element came from inside a web area, meaning under a container whose rule reads
/// `ChildrenSource.searchPredicate`. The action planner activates the two kinds differently.
public enum ElementContent: Hashable, Sendable {
    case native
    case web
}

public struct Found<Element> {
    public let element: Element
    public let role: String
    /// The node's frame clipped by every clipping ancestor and the root clip. Never empty.
    public let visibleFrame: GlobalRect
    public let content: ElementContent
}

public struct Harvest<Element> {
    public var found: [Found<Element>] = []
    public var nodesRead = 0
    /// Nil when the walk finished. Otherwise `found` is a valid partial result.
    public var stop: StopReason?
    /// The raw result count of each web area that answered the search, in visit order.
    /// A zero makes the probe turn on Chromium and Electron accessibility for the next scan.
    public var webAreaResults: [Int] = []
}

public enum Traversal {
    /// Breadth-first walk of one root (a window, a menu bar, the Dock list) under `roles`.
    ///
    /// Invariants:
    /// - Each node costs one `facts` IPC. A container costs a `children` IPC unless its frame lies
    ///   outside the clip, so off-screen subtrees cost one IPC total.
    /// - A missing or empty frame is common on structural nodes (the Dock's `AXApplication` root,
    ///   SwiftUI and web groups). Such a container passes its clip through. Such a hint is no candidate.
    /// - A node whose visible frame `isFullyCovered` reports as hidden is skipped with its subtree,
    ///   before its children are read. The scanner builds the closure per root with `Visibility.coverTest`.
    /// - Breadth-first order visits toolbars and sidebars before deep document content, so a walk
    ///   cut short by the budget or node limit still returns the shallow controls.
    /// - `shouldStop` is checked before every IPC. Cancellation and the scan deadline both feed it.
    /// - `.unresponsive` from any call ends the walk with the partial result.
    /// - Everything found under a `.searchPredicate` container is `.web`, whether it came from the
    ///   search or from the `.children` fallback. Everything else is `.native`.
    public static func harvest<R: ElementReader>(
        root: R.Element,
        clip: GlobalRect,
        reader: R,
        roles: RoleTable,
        maxNodes: Int,
        isFullyCovered: (GlobalRect) -> Bool,
        shouldStop: () -> Bool
    ) -> Harvest<R.Element> {
        var result = Harvest<R.Element>()
        var queue: [(element: R.Element, clip: GlobalRect, content: ElementContent)] = [(root, clip, .native)]
        var head = 0

        /// Nil skips the node and its subtree: the read failed, the frame lies outside `clip`, or a
        /// window in front hides all of it.
        func read(_ element: R.Element, within clip: GlobalRect) -> (NodeFacts, Placement)? {
            if shouldStop() { result.stop = .budget; return nil }
            if result.nodesRead >= maxNodes { result.stop = .nodeLimit; return nil }
            do throws(ReadError) {
                let facts = try reader.facts(of: element)
                result.nodesRead += 1
                guard let frame = facts.frame, !frame.isEmpty else { return (facts, .frameless) }
                let visible = frame.intersection(clip)
                return visible.isEmpty || isFullyCovered(visible) ? nil : (facts, .visible(visible))
            } catch {
                result.nodesRead += 1
                if error == .unresponsive { result.stop = .unresponsive }
                return nil
            }
        }

        func children(of element: R.Element, from source: ChildrenSource) -> (elements: [R.Element], terminal: Bool)? {
            if shouldStop() { result.stop = .budget; return nil }
            do throws(ReadError) {
                if case .searchPredicate = source {
                    do throws(ReadError) {
                        return (try reader.children(of: element, from: source), true)
                    } catch where error == .unsupported {
                        return (try reader.children(of: element, from: .children), false)
                    }
                }
                return (try reader.children(of: element, from: source), false)
            } catch {
                if error == .unresponsive { result.stop = .unresponsive }
                return nil
            }
        }

        while head < queue.count, result.stop == nil {
            let (element, clip, content) = queue[head]
            head += 1
            guard let (facts, placement) = read(element, within: clip) else { continue }

            switch roles.rule(for: facts.role) {
            case .skip:
                continue
            case .hint:
                if facts.isEnabled, case .visible(let frame) = placement {
                    result.found.append(Found(element: element, role: facts.role, visibleFrame: frame, content: content))
                }
            case .container(let source, let clips):
                let childClip = if clips, case .visible(let frame) = placement { frame } else { clip }
                let kidContent: ElementContent = if case .searchPredicate = source { .web } else { content }
                guard let (kids, terminal) = children(of: element, from: source) else { continue }
                if terminal {
                    result.webAreaResults.append(kids.count)
                    for kid in kids {
                        guard result.stop == nil else { break }
                        guard case let (kidFacts, .visible(kidFrame))? = read(kid, within: childClip),
                              kidFacts.isEnabled, roles.rule(for: kidFacts.role) == .hint
                        else { continue }
                        result.found.append(Found(element: kid, role: kidFacts.role, visibleFrame: kidFrame, content: kidContent))
                    }
                } else {
                    queue.append(contentsOf: kids.map { ($0, childClip, kidContent) })
                }
            }
        }
        return result
    }
}

/// Where a node sits relative to its clip, once its frame is known to intersect it.
private enum Placement {
    case visible(GlobalRect)
    /// No frame, or an empty one. Not drawable, so never a candidate, but its children may be.
    case frameless
}
