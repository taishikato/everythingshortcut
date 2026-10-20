#if DEBUG
import AppKit
import ApplicationServices
import AutomationWire
import CoreGraphics
import HintCore
import os

/// The app window's side of the automation hook. `dump` returns nil while the window was never opened.
struct PracticeHook {
    let open: @MainActor () -> Void
    let dump: @MainActor () -> PracticeDump?
}

struct PracticeDump {
    let practice: Practice
    let target: GlobalRect?
    let window: GlobalRect?
}

/// DEBUG-only remote control for end-to-end tests from an untrusted shell.
///
/// Compiled only in DEBUG and started only with `--automation`, so release builds carry none of it.
/// It does three things and nothing else.
/// - Posts real input with `CGEventPost(.cghidEventTap)`. This process is Accessibility-trusted,
///   so the events travel the physical path: Carbon hotkey matching, then our own session tap.
///   Input never reaches the reducer any other way.
/// - Writes `SessionSnapshot`, read from the controller's state. The hints in the snapshot are the
///   hints in `HintMachine.phase`, the single source the overlay also renders from.
/// - Configures settings through `HintController.configure`, without persisting them, so a run never
///   rewrites the user's saved settings, and opens the app window's try step, which it never closes.
///
/// A `press` reply is written as soon as the events are posted. The resulting phase change happens on
/// later run-loop turns, so the driver polls `status` until it sees the phase it expects.
@MainActor
final class AutomationServer {
    private let controller: HintController
    private let practice: PracticeHook
    private let layout = KeyboardLayout()
    private var observer: NSObjectProtocol?
    private let log = Logger(subsystem: "com.taishikato.EverythingShortcut", category: "automation")

    init(controller: HintController, practice: PracticeHook) {
        self.controller = controller
        self.practice = practice
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: AutomationChannel.command, object: nil, queue: .main
        ) { [weak self] note in
            let json = note.userInfo?[AutomationChannel.payloadKey] as? String
            MainActor.assumeIsolated { self?.receive(json) }
        }
        log.notice("automation listening")
    }

    private func receive(_ json: String?) {
        guard let json, let request = try? JSONDecoder().decode(AutomationRequest.self, from: Data(json.utf8)) else {
            log.error("dropped a malformed automation request")
            return
        }
        let error: String? = switch request.command {
        case .status: nil
        case .press(let inputs): post(inputs)
        case .configure(let keyCode, let modifiers): configure(keyCode: keyCode, modifiers: modifiers)
        case .openPractice: openPractice()
        }
        let reply = AutomationReply(id: request.id, error: error, snapshot: snapshot())
        do {
            try JSONEncoder().encode(reply).write(to: URL(fileURLWithPath: request.replyPath), options: .atomic)
        } catch {
            log.error("could not write the reply to \(request.replyPath, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Validates like Settings does and never falls back, so a bad request fails loudly.
    private func configure(keyCode: UInt16, modifiers: UInt8) -> String? {
        guard Modifiers.all.isSuperset(of: Modifiers(rawValue: modifiers)) else { return "unknown modifier bits \(modifiers)" }
        switch HotKey.validated(keyCode: keyCode, modifiers: Modifiers(rawValue: modifiers)) {
        case .success(let trigger):
            controller.configure(UserSettings(trigger: trigger))
            return nil
        case .failure(let error):
            return error.message
        }
    }

    private func openPractice() -> String? {
        practice.open()
        return nil
    }

    /// Resolves every key before posting any, so a request with an unknown letter posts nothing.
    private func post(_ inputs: [AutomationInput]) -> String? {
        var events: [() -> Void] = []
        for input in inputs {
            switch input {
            case .trigger:
                let trigger = controller.settings.trigger
                events.append { self.chord(trigger) }
            case .chord(let keyCode, let modifiers):
                events.append { self.chord(HotKey(keyCode: keyCode, modifiers: Modifiers(rawValue: modifiers))) }
            case .escape:
                events.append { self.key(VirtualKey.escape) }
            case .backspace:
                events.append { self.key(VirtualKey.delete) }
            case .letters(let letters):
                for c in letters {
                    guard let code = layout.keyCode(for: c) else { return "no key code for \(c) in the ASCII-capable layout" }
                    events.append { self.key(code) }
                }
            case .click(let x, let y):
                events.append { self.click(CGPoint(x: x, y: y)) }
            }
        }
        events.forEach { $0() }
        return nil
    }

    private let source = CGEventSource(stateID: .hidSystemState)

    private func key(_ code: UInt16, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Presses the modifier keys, the key, then releases the modifiers, as a person would.
    private func chord(_ hotKey: HotKey) {
        let modifiers: [(Modifiers, CGKeyCode, CGEventFlags)] = [
            (.control, 59, .maskControl), (.option, 58, .maskAlternate), (.shift, 56, .maskShift), (.command, 55, .maskCommand),
        ].filter { hotKey.modifiers.contains($0.0) }
        var held: CGEventFlags = []
        for (_, code, flag) in modifiers {
            held.insert(flag)
            modifierEvent(code, flags: held)
        }
        key(hotKey.keyCode, flags: held)
        for (_, code, flag) in modifiers.reversed() {
            held.remove(flag)
            modifierEvent(code, flags: held)
        }
    }

    private func modifierEvent(_ code: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func click(_ point: CGPoint) {
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.post(tap: .cghidEventTap)
        }
    }

    private func snapshot() -> SessionSnapshot {
        var phaseName = "idle"
        var typed = ""
        var hints: [HintDump] = []
        switch controller.phase {
        case .idle: phaseName = "idle"
        case .scanning: phaseName = "scanning"
        case .performing: phaseName = "performing"
        case .showing(let board):
            phaseName = "showing"
            typed = board.typed
            hints = board.matching.map { h in
                HintDump(label: h.label, pid: h.candidate.pid.raw, surface: Self.describe(h.candidate.surface), frame: Self.dump(h.candidate.frame))
            }
        }
        let practiceState = practice.dump()
        return SessionSnapshot(
            phase: phaseName,
            typed: typed,
            hints: hints,
            overlayPanels: controller.overlayPanelFrames.map { RectDump(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
            accessibilityTrusted: AXIsProcessTrusted(),
            triggerRegistered: controller.triggerRegistration == .registered,
            trigger: TriggerDump(keyCode: controller.settings.trigger.keyCode, modifiers: controller.settings.trigger.modifiers.rawValue),
            lastScan: controller.lastScanStats.map(Self.dump),
            lastPerform: controller.lastPerform.map(Self.dump),
            practice: practiceState.map { String(describing: $0.practice) },
            practiceTarget: practiceState?.target.map(Self.dump),
            appWindow: practiceState?.window.map(Self.dump)
        )
    }

    private static func dump(_ s: ScanStats) -> ScanDump {
        ScanDump(
            durationMs: s.duration / .milliseconds(1),
            nodesRead: s.nodesRead,
            candidatesBeforeOcclusion: s.candidatesBeforeOcclusion,
            candidates: s.candidates,
            apps: s.apps.map { a in
                AppScanDump(
                    pid: a.pid.raw, roots: a.roots, durationMs: a.duration / .milliseconds(1), nodesRead: a.nodesRead,
                    stop: a.stop.map { String(describing: $0) }, candidates: a.candidates,
                    webAreaResults: a.webAreaResults, webFlags: a.webFlags
                )
            },
            droppedStatusItems: s.droppedStatusItems.map { d in
                StatusItemDuplicateDump(frame: dump(d.frame), keptPid: d.kept.raw, droppedPid: d.dropped.raw)
            }
        )
    }

    private static func dump(_ p: PerformReport) -> PerformDump {
        var steps: [String] = []
        if p.plan.raiseWindow { steps.append("raise") }
        switch p.plan.act {
        case .press: steps.append("press")
        case .click: steps.append("click")
        }
        let act = switch p.act {
        case .pressed(let error): "press: \(error == .success ? "success" : "error \(error.rawValue)")"
        case .pressFailedThenClicked(let error): "press: error \(error.rawValue), then click"
        case .clicked: "click"
        }
        return PerformDump(
            pid: p.pid.raw, surface: describe(p.surface), plan: steps.joined(separator: ", "), act: act,
            frontmostBefore: p.frontmostBefore, frontmostAfter: p.frontmostAfter
        )
    }

    private static func dump(_ r: GlobalRect) -> RectDump {
        RectDump(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    private static func describe(_ surface: Surface) -> String {
        switch surface {
        case .window(let id): "window:\(id.raw)"
        case .menuBar: "menuBar"
        case .statusItem: "statusItem"
        case .dock: "dock"
        }
    }
}
#endif
