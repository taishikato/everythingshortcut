/// A point in global display space.
/// Origin at the top-left of the primary display, y grows downward.
/// AX positions, CGWindowList bounds, CGEvent locations and CGDisplayBounds all use this space,
/// so every scan, occlusion, and click computation stays in it with no conversion.
public struct GlobalPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in global display space. See `GlobalPoint`.
/// A rect with non-positive width or height is empty and contains no point.
public struct GlobalRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let empty = GlobalRect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var origin: GlobalPoint { GlobalPoint(x: x, y: y) }
    public var center: GlobalPoint { GlobalPoint(x: x + width / 2, y: y + height / 2) }

    /// Half-open containment, so two adjacent rects never both contain a shared edge point.
    public func contains(_ p: GlobalPoint) -> Bool {
        !isEmpty && p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    public func contains(_ r: GlobalRect) -> Bool {
        !isEmpty && !r.isEmpty && r.minX >= minX && r.maxX <= maxX && r.minY >= minY && r.maxY <= maxY
    }

    public func intersection(_ other: GlobalRect) -> GlobalRect {
        let x0 = max(minX, other.minX)
        let y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX)
        let y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return .empty }
        return GlobalRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func intersects(_ other: GlobalRect) -> Bool { !intersection(other).isEmpty }

    /// Smallest rect containing both. Empty operands are ignored.
    public func union(_ other: GlobalRect) -> GlobalRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = min(minX, other.minX)
        let y0 = min(minY, other.minY)
        return GlobalRect(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }
}

/// A rectangle in AppKit's global space: origin at the bottom-left of the primary display, y grows upward.
/// Only `NSWindow` frames use it. Distinct from `GlobalRect` so the two never mix silently.
public struct AppKitRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The only conversion between global display space and AppKit space in the codebase.
/// `primaryDisplayHeight` is the height of the display whose global origin is (0, 0).
extension GlobalRect {
    public func appKitRect(primaryDisplayHeight h: Double) -> AppKitRect {
        AppKitRect(x: x, y: h - (y + height), width: width, height: height)
    }

    public init(_ r: AppKitRect, primaryDisplayHeight h: Double) {
        self.init(x: r.x, y: h - (r.y + r.height), width: r.width, height: r.height)
    }
}

/// A point local to one display, origin at that display's top-left, y down.
/// The overlay draws into a flipped view per display, so this is its drawing space.
public struct LocalPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct DisplayID: Hashable, Sendable {
    public let raw: UInt32

    public init(_ raw: UInt32) { self.raw = raw }
}

/// An active display and its bounds in global display space (`CGDisplayBounds`).
public struct Display: Hashable, Sendable {
    public let id: DisplayID
    public let bounds: GlobalRect

    public init(id: DisplayID, bounds: GlobalRect) {
        self.id = id
        self.bounds = bounds
    }

    /// Translation only. Both spaces are y-down, so no flip happens here.
    public func local(_ p: GlobalPoint) -> LocalPoint {
        LocalPoint(x: p.x - bounds.x, y: p.y - bounds.y)
    }
}

extension Array where Element == Display {
    /// The display whose global origin is (0, 0). AppKit measures y from its bottom edge.
    public var primary: Display? { first { $0.bounds.x == 0 && $0.bounds.y == 0 } }

    /// Bounding box of all displays, used as the outermost traversal clip.
    public var unionBounds: GlobalRect { reduce(GlobalRect.empty) { $0.union($1.bounds) } }

    public func containing(_ p: GlobalPoint) -> Display? { first { $0.bounds.contains(p) } }
}
