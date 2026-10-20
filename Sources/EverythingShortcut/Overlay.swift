import AppKit
import CoreGraphics
import Desktop
import HintCore

/// The badges on screen. One borderless, transparent, non-activating panel per display with badges.
///
/// Declarative. `render` makes the screen match its argument and keeps no other state, so a repeated
/// or late render cannot stack overlays. Panels are keyed by display id, so two panels on one display
/// cannot exist. `render([])` removes every panel.
@MainActor
final class Overlay {
    private var panels: [DisplayID: OverlayPanel] = [:]

    func render(_ layout: [DisplayBadges], primaryDisplayHeight: Double) {
        let wanted = Set(layout.map(\.display.id))
        for (id, panel) in panels where !wanted.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for entry in layout {
            let panel = panels[entry.display.id] ?? OverlayPanel()
            panels[entry.display.id] = panel
            panel.setFrame(entry.display.bounds.appKitRect(primaryDisplayHeight: primaryDisplayHeight).nsRect, display: false)
            panel.canvas.badges = entry.badges
            panel.orderFrontRegardless()
        }
    }

    var panelFrames: [AppKitRect] { panels.values.map { AppKitRect($0.frame) } }
}

/// Never key, never main, never activates, ignores the mouse, follows every Space.
/// The screen-saver level is above menus, the menu bar, status items and the Dock.
final class OverlayPanel: NSPanel {
    let canvas = BadgeCanvas()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = canvas
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A one-line notice in the badge style, centered near the top of the display that holds the mouse,
/// just below the menu bar. It stays 2.5 s, fades out, and a new one replaces the current one.
/// The panel sits at the overlay's level, so the scan treats it like the badge panels: transparent, never planned.
@MainActor
final class Notice {
    private let panel = NoticePanel()
    private var hiding: Task<Void, Never>?

    func show(_ text: String) {
        hiding?.cancel()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        panel.pill.message = text
        let size = panel.pill.intrinsicContentSize
        let top = screen.visibleFrame.maxY - 8
        panel.setFrame(NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height), display: true)
        // A zero-length group replaces a fade still running from the notice this one replaces.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }, completionHandler: nil)
        panel.orderFrontRegardless()
        hiding = Task { [panel] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

final class NoticePanel: NSPanel {
    let pill = NoticePill()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = pill
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NoticePill: NSView {
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let padding = NSSize(width: 14, height: 6)
    private static let shadowRoom: CGFloat = 4
    private var text = NSAttributedString()

    var message = "" {
        didSet {
            text = NSAttributedString(string: message, attributes: [.font: Self.font, .foregroundColor: BadgeStyle.text])
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let size = text.size()
        return NSSize(
            width: ceil(size.width) + 2 * (Self.padding.width + Self.shadowRoom),
            height: ceil(size.height) + 2 * (Self.padding.height + Self.shadowRoom)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: Self.shadowRoom, dy: Self.shadowRoom)
        let radius = rect.height / 2
        let shape = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: BadgeStyle.shadow.cgColor)
        context.addPath(shape)
        context.setFillColor(BadgeStyle.fillBottom.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.drawLinearGradient(BadgeStyle.gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.minX, y: rect.maxY), options: [])
        context.restoreGState()

        context.addPath(shape)
        context.setStrokeColor(BadgeStyle.border.cgColor)
        context.setLineWidth(1)
        context.strokePath()

        text.draw(at: NSPoint(x: rect.minX + Self.padding.width, y: rect.minY + Self.padding.height))
    }
}

/// Draws every badge of one display in one `draw(_:)`, with no view per badge.
/// Flipped, so `Badge.origin` (display-local, y down) is the drawing coordinate with no conversion.
///
/// The shadow and the border each cost one path operation for all badges together. Only the gradient
/// and the text are per badge. Text layout is cached per label and typed count, so a keystroke
/// redraws without laying out text again.
final class BadgeCanvas: NSView {
    var badges: [Badge] = [] {
        didSet { needsDisplay = true }
    }

    private var labels: [LabelKey: (text: NSAttributedString, size: NSSize)] = [:]

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !badges.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let placed = badges.map { badge in
            let (text, size) = label(for: badge)
            let width = ceil(size.width) + 2 * BadgeStyle.padding.width
            let height = ceil(size.height) + 2 * BadgeStyle.padding.height
            // Clamped inside the display, so badges at its right or bottom edge stay readable.
            let x = min(max(badge.origin.x, bounds.minX), bounds.maxX - width)
            let y = min(max(badge.origin.y, bounds.minY), bounds.maxY - height)
            return (rect: NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height), text: text)
        }

        let shapes = CGMutablePath()
        for (rect, _) in placed {
            shapes.addRoundedRect(in: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: BadgeStyle.cornerRadius, cornerHeight: BadgeStyle.cornerRadius)
        }

        context.saveGState()
        // Shadow offsets are in device space, which is y up even in a flipped view.
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: BadgeStyle.shadow.cgColor)
        context.addPath(shapes)
        context.setFillColor(BadgeStyle.fillBottom.cgColor)
        context.fillPath()
        context.restoreGState()

        for (rect, _) in placed {
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: BadgeStyle.cornerRadius, cornerHeight: BadgeStyle.cornerRadius, transform: nil))
            context.clip()
            context.drawLinearGradient(BadgeStyle.gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.minX, y: rect.maxY), options: [])
            context.restoreGState()
        }

        context.addPath(shapes)
        context.setStrokeColor(BadgeStyle.border.cgColor)
        context.setLineWidth(1)
        context.strokePath()

        for (rect, text) in placed {
            text.draw(at: NSPoint(x: rect.minX + BadgeStyle.padding.width, y: rect.minY + BadgeStyle.padding.height))
        }
    }

    private func label(for badge: Badge) -> (text: NSAttributedString, size: NSSize) {
        let key = LabelKey(text: badge.text, typedCount: badge.typedCount)
        if let cached = labels[key] { return cached }
        let text = NSMutableAttributedString(string: badge.text, attributes: [.font: BadgeStyle.font, .foregroundColor: BadgeStyle.text])
        let typed = min(badge.typedCount, (badge.text as NSString).length)
        text.addAttribute(.foregroundColor, value: BadgeStyle.typedText, range: NSRange(location: 0, length: typed))
        let entry = (text: NSAttributedString(attributedString: text), size: text.size())
        labels[key] = entry
        return entry
    }
}

private struct LabelKey: Hashable {
    let text: String
    let typedCount: Int
}

/// Vimium's badge look: a yellow gradient, a darker amber border, a light shadow, dark bold uppercase
/// letters, and typed letters dimmed to the border's amber.
@MainActor
enum BadgeStyle {
    static let font = NSFont.boldSystemFont(ofSize: 11)
    static let text = NSColor(srgbRed: 0.19, green: 0.15, blue: 0.02, alpha: 1)
    static let typedText = NSColor(srgbRed: 0.83, green: 0.67, blue: 0.23, alpha: 1)
    static let fillTop = NSColor(srgbRed: 1.0, green: 0.97, blue: 0.52, alpha: 1)
    static let fillBottom = NSColor(srgbRed: 1.0, green: 0.77, blue: 0.26, alpha: 1)
    static let border = NSColor(srgbRed: 0.76, green: 0.54, blue: 0.13, alpha: 1)
    static let shadow = NSColor(white: 0, alpha: 0.3)
    static let padding = NSSize(width: 3, height: 1)
    static let cornerRadius: CGFloat = 3
    static let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [fillTop.cgColor, fillBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
}
