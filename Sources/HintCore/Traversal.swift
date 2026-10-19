/// The facts the traversal needs about one node, read in one batched IPC
/// (`AXUIElementCopyMultipleAttributeValues` over role, position, size, enabled).
public struct NodeFacts: Hashable, Sendable {
    public var role: String
    public var frame: GlobalRect
    /// Elements that do not report `AXEnabled` count as enabled.
    public var isEnabled: Bool

    public init(role: String, frame: GlobalRect, isEnabled: Bool = true) {
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

public struct Found<Element> {
    public let element: Element
    public let role: String
    /// The node's frame clipped by every clipping ancestor and the root clip. Never empty.
    public let visibleFrame: GlobalRect
}

public struct Harvest<Element> {
    public var found: [Found<Element>] = []
    public var nodesRead = 0
    /// Nil when the walk finished. Otherwise `found` is a valid partial result.
    public var stop: StopReason?
    /// Web areas whose search returned nothing. The probe uses this to turn on Chromium/Electron
    /// accessibility for the next scan.
    public var emptySearchContainers = 0
}

public enum Traversal {
    /// Breadth-first walk of one root (a window, a menu bar, the Dock list) under `roles`.
    ///
    /// Invariants:
    /// - Each node costs one `facts` IPC. A node costs a `children` IPC only when its rule is
    ///   `.container` and its visible frame is non-empty. Off-screen subtrees cost one IPC total.
    /// - Breadth-first order visits toolbars and sidebars before deep document content, so a walk
    ///   cut short by the budget or node limit still returns the shallow controls.
    /// - `shouldStop` is checked before every IPC. Cancellation and the scan deadline both feed it.
    /// - `.unresponsive` from any call ends the walk with the partial result.
    public static func harvest<R: ElementReader>(
        root: R.Element,
        clip: GlobalRect,
        reader: R,
        roles: RoleTable,
        maxNodes: Int,
        shouldStop: () -> Bool
    ) -> Harvest<R.Element> {
        var result = Harvest<R.Element>()
        var queue: [(element: R.Element, clip: GlobalRect)] = [(root, clip)]
        var head = 0

        func read(_ element: R.Element, within clip: GlobalRect) -> (NodeFacts, GlobalRect)? {
            if shouldStop() { result.stop = .budget; return nil }
            if result.nodesRead >= maxNodes { result.stop = .nodeLimit; return nil }
            do throws(ReadError) {
                let facts = try reader.facts(of: element)
                result.nodesRead += 1
                let visible = facts.frame.intersection(clip)
                return visible.isEmpty ? nil : (facts, visible)
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
            let (element, clip) = queue[head]
            head += 1
            guard let (facts, visible) = read(element, within: clip) else { continue }

            switch roles.rule(for: facts.role) {
            case .skip:
                continue
            case .hint:
                if facts.isEnabled {
                    result.found.append(Found(element: element, role: facts.role, visibleFrame: visible))
                }
            case .container(let source, let clips):
                let childClip = clips ? visible : clip
                guard let (kids, terminal) = children(of: element, from: source) else { continue }
                if terminal {
                    if kids.isEmpty { result.emptySearchContainers += 1 }
                    for kid in kids {
                        guard result.stop == nil else { break }
                        guard let (kidFacts, kidVisible) = read(kid, within: childClip), kidFacts.isEnabled else { continue }
                        result.found.append(Found(element: kid, role: kidFacts.role, visibleFrame: kidVisible))
                    }
                } else {
                    queue.append(contentsOf: kids.map { ($0, childClip) })
                }
            }
        }
        return result
    }
}
