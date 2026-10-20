import AppKit
import Desktop
import HintCore

/// Two windows with known controls, laid out so one scan exercises every visibility rule.
///
///     +----------- Back ------------+
///     |                [back-visible]|
///     |  +------- Front -------+     |
///     |  | [front-1] [front-2] |     |
///     |  | (covers back-covered)     |
///     +--|                     |-----+
///        | [front-field......] |
///        +---------------------+
///
/// Front covers back-covered entirely, so it must get no hint. back-visible sits in the exposed part
/// of Back, a background window, so pressing it tests the background-window click policy. front-field
/// advertises no AXPress, so it tests the click path.
///
/// Both windows float above normal windows, so another app's windows cannot cover them while the e2e
/// run moves activation away from es-dev. Every press is recorded with `NSApp.isActive` at that
/// moment, which tells "pressed in place" from "raised, then pressed".
@MainActor
final class Fixture: NSObject {
    struct Press: Equatable {
        let name: String
        let appWasActive: Bool
    }

    static let controlNames = ["back-covered", "back-visible", "front-1", "front-2", "front-field"]

    var onPress: (Press) -> Void = { _ in }
    private(set) var presses: [Press] = []
    let back: NSWindow
    let front: NSWindow
    private var controls: [String: NSView] = [:]

    override init() {
        let area = (NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)).origin
        let base = NSPoint(x: area.x + 80, y: area.y + 80)
        back = Self.window("Back", NSRect(x: base.x + 20, y: base.y + 50, width: 520, height: 260))
        front = Self.window("Front", NSRect(x: base.x, y: base.y, width: 340, height: 150))
        super.init()
        add(button("back-covered"), named: "back-covered", to: back, at: NSRect(x: 20, y: 20, width: 110, height: 32))
        add(button("back-visible"), named: "back-visible", to: back, at: NSRect(x: 390, y: 210, width: 110, height: 32))
        add(button("front-1"), named: "front-1", to: front, at: NSRect(x: 20, y: 100, width: 100, height: 32))
        add(button("front-2"), named: "front-2", to: front, at: NSRect(x: 140, y: 100, width: 100, height: 32))
        let field = RecordingField(frame: .zero)
        field.placeholderString = "front-field"
        field.onMouseDown = { [weak self] in self?.record("front-field") }
        add(field, named: "front-field", to: front, at: NSRect(x: 20, y: 20, width: 200, height: 22))
    }

    func show() {
        back.orderFrontRegardless()
        front.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The fixture floats, so it would cover the app window. Only the last e2e check calls this.
    func hide() {
        back.orderOut(nil)
        front.orderOut(nil)
    }

    /// Control frames in global display space, through the core's single AppKit conversion.
    func frame(of name: String) -> GlobalRect? {
        guard let view = controls[name], let window = view.window else { return nil }
        let onScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        return GlobalRect(AppKitRect(onScreen), primaryDisplayHeight: Desktop.displays().primary?.bounds.height ?? 0)
    }

    /// A point in Front that holds no control, for a click that must reach no fixture control.
    func emptyPointInFront() -> GlobalPoint {
        let onScreen = front.convertToScreen(NSRect(x: 300, y: 70, width: 1, height: 1))
        return GlobalRect(AppKitRect(onScreen), primaryDisplayHeight: Desktop.displays().primary?.bounds.height ?? 0).origin
    }

    func describe() -> String {
        var lines = ["fixture pid=\(ProcessInfo.processInfo.processIdentifier)"]
        for window in [back, front] {
            let frame = GlobalRect(AppKitRect(window.frame), primaryDisplayHeight: Desktop.displays().primary?.bounds.height ?? 0)
            lines.append("  window #\(window.windowNumber) \(window.title) \(Self.describe(frame))")
        }
        for name in Self.controlNames {
            lines.append("  control \(name) \(frame(of: name).map(Self.describe) ?? "-")")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func pressed(_ sender: NSButton) {
        record(sender.title)
    }

    private func record(_ name: String) {
        let press = Press(name: name, appWasActive: NSApp.isActive)
        presses.append(press)
        onPress(press)
    }

    private func button(_ title: String) -> NSButton {
        NSButton(title: title, target: self, action: #selector(pressed(_:)))
    }

    private func add(_ view: NSView, named name: String, to window: NSWindow, at frame: NSRect) {
        view.frame = frame
        window.contentView?.addSubview(view)
        controls[name] = view
    }

    private static func window(_ title: String, _ contentRect: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: contentRect, styleMask: [.titled], backing: .buffered, defer: false)
        let sink = FocusSink()
        window.contentView = sink
        window.initialFirstResponder = sink
        window.title = title
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        return window
    }

    private static func describe(_ r: GlobalRect) -> String {
        "(\(Int(r.x)),\(Int(r.y)) \(Int(r.width))x\(Int(r.height)))"
    }
}

/// Takes the initial focus, so front-field is not already editing when its click arrives, and the
/// click reaches the field instead of its field editor.
private final class FocusSink: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Records a click on itself. A text field has no action for a plain click, so the press log hooks mouseDown.
private final class RecordingField: NSTextField {
    var onMouseDown: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        onMouseDown()
        super.mouseDown(with: event)
    }
}
