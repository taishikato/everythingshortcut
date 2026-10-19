import AppKit
import AutomationWire
import Desktop
import HintCore

/// Drives the running DEBUG app (launched with `--automation`) against the in-process fixture.
/// Prints one VERIFIED or NOT VERIFIED line per check, with the measured value.
/// Exit 0 when every check is verified, 1 when one is not, 2 when the app is missing or untrusted.
@MainActor
struct EndToEnd {
    let fixture: Fixture
    let outDirectory: URL

    private static let grantStep = "Grant Accessibility to build/EverythingShortcut.app in System Settings > Privacy & Security > Accessibility, then rerun scripts/e2e.sh."

    func run() async -> Int32 {
        try? FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        let link = AppLink(replyDirectory: outDirectory)
        var log = CheckLog()

        guard let first = try? await link.waitForApp() else {
            log.record("the app answers over AutomationWire within 10 s", false, "no reply. Is build/EverythingShortcut.app running with --automation?")
            return 2
        }
        guard first.accessibilityTrusted else {
            log.record("the app is Accessibility-trusted", false, Self.grantStep)
            return 2
        }
        log.record("the app is Accessibility-trusted", true, "trusted")
        log.record("the trigger chord is registered", first.triggerRegistered, first.triggerRegistered ? "registered" : "another app holds it")

        checkPlanWithoutAX(&log)

        await log.step("trigger shows hints and no app's scan stopped on the budget or the node limit") {
            let shown = try await link.press([.trigger], then: "showing")
            try save(shown, as: "scan.json")
            guard let scan = shown.lastScan else { return (false, "the snapshot has no scan") }
            let slowest = scan.apps.sorted { $0.durationMs > $1.durationMs }.prefix(3)
                .map { "pid \($0.pid) \(Int($0.durationMs)) ms" }
            let stopped = scan.apps.compactMap { app in app.stop.map { (pid: app.pid, why: $0) } }
            let cutShort = stopped.filter { $0.why == "budget" || $0.why == "nodeLimit" }
            let stops = stopped.isEmpty ? "none" : stopped.map { "pid \($0.pid) \($0.why)" }.joined(separator: "; ")
            return (cutShort.isEmpty, "\(Int(scan.durationMs)) ms, \(shown.hints.count) hints, slowest: \(slowest.joined(separator: "; ")), stopped: \(stops)")
        }

        await log.step("visible fixture controls have hints and the covered button has none") {
            let s = try await link.status()
            let missing = ["back-visible", "front-1", "front-2", "front-field"].filter { hint(for: $0, in: s) == nil }
            let covered = hint(for: "back-covered", in: s)
            return (missing.isEmpty && covered == nil, "missing: \(missing), back-covered hint: \(covered?.label ?? "none")")
        }

        await log.step("badges are captured on screen, one panel per display at most") {
            let s = try await link.status()
            let png = outDirectory.appendingPathComponent("hints.png")
            let captured = await screencapture(png)
            let displays = Desktop.displays().count
            return (captured && !s.overlayPanels.isEmpty && s.overlayPanels.count <= displays, "\(s.overlayPanels.count) panels on \(displays) displays, \(captured ? png.path : "screencapture failed")")
        }

        await log.step("a typed letter narrows the hints and backspace restores them") {
            let all = try await link.status()
            guard let twoLetter = all.hints.first(where: { $0.label.count == 2 }), let letter = twoLetter.label.first else {
                return (false, "only \(all.hints.count) hints, so no two-letter label to narrow with")
            }
            let narrowed = try await link.press([.letters(String(letter))])
            let restored = try await link.press([.backspace])
            let ok = narrowed.typed == String(letter) && narrowed.hints.allSatisfy { $0.label.first == letter }
                && narrowed.hints.count < all.hints.count && restored.typed.isEmpty && restored.hints.count == all.hints.count
            return (ok, "\(all.hints.count) hints, \(narrowed.hints.count) after '\(letter)', \(restored.hints.count) after backspace")
        }

        await log.step("escape cancels and clicks nothing") {
            let before = fixture.presses.count
            let idle = try await link.press([.escape], then: "idle")
            return (idle.overlayPanels.isEmpty && fixture.presses.count == before, "\(idle.overlayPanels.count) panels, \(fixture.presses.count - before) presses")
        }

        await log.step("a mouse click anywhere cancels and presses no fixture control") {
            _ = try await link.press([.trigger], then: "showing")
            let before = fixture.presses.count
            let point = fixture.emptyPointInFront()
            let idle = try await link.press([.click(x: point.x, y: point.y)], then: "idle")
            return (idle.overlayPanels.isEmpty && fixture.presses.count == before, "\(idle.overlayPanels.count) panels, \(fixture.presses.count - before) presses")
        }

        await log.step("the trigger toggles without stacking panels") {
            _ = try await link.press([.trigger, .trigger])
            try await Task.sleep(for: .milliseconds(300))
            let twice = try await link.waitFor(phase: "idle")
            let thrice = try await link.press([.trigger, .trigger, .trigger], then: "showing")
            _ = try await link.press([.escape], then: "idle")
            let displays = Desktop.displays().count
            return (twice.overlayPanels.isEmpty && thrice.overlayPanels.count <= displays, "twice: \(twice.phase), \(twice.overlayPanels.count) panels. three times: \(thrice.overlayPanels.count) panels")
        }

        await log.step("typing the text field's label clicks it") {
            let pressed = try await press("front-field", link: link)
            return (pressed.name == "front-field" && pressed.act == "click", pressed.detail)
        }

        await log.step("typing a background window's label raises it and presses the button") {
            moveActivationAway()
            try await Task.sleep(for: .milliseconds(500))
            let wasActive = NSApp.isActive
            let pressed = try await press("back-visible", link: link)
            let order = Desktop.windowSnapshot().windows.map(\.id)
            let backID = WindowID(UInt32(fixture.back.windowNumber))
            let frontID = WindowID(UInt32(fixture.front.windowNumber))
            let raised = (order.firstIndex(of: backID) ?? .max) < (order.firstIndex(of: frontID) ?? .max)
            return (pressed.name == "back-visible" && raised, "\(pressed.detail), es-dev active before: \(wasActive), Back raised: \(raised)")
        }

        if let final = try? await link.status() { try? save(final, as: "final.json") }
        print("\(log.verified) of \(log.total) checks VERIFIED. Snapshots in \(outDirectory.path).")
        return log.verified == log.total ? 0 : 1
    }

    /// The window stack and visibility rules on the live desktop, with no AX call.
    private func checkPlanWithoutAX(_ log: inout CheckLog) {
        let snapshot = Desktop.windowSnapshot()
        let ids = Set(snapshot.windows.map(\.id))
        let backID = WindowID(UInt32(fixture.back.windowNumber))
        let frontID = WindowID(UInt32(fixture.front.windowNumber))
        let appPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.taishikato.EverythingShortcut").first
            .map { PID($0.processIdentifier) } ?? PID(-1)
        func visible(_ name: String) -> Bool {
            guard let frame = fixture.frame(of: name) else { return false }
            return Visibility.isVisible(frame.center, surface: .window(backID), pid: Desktop.selfPID, in: snapshot, selfPID: appPID)
        }
        let ok = ids.contains(backID) && ids.contains(frontID) && !visible("back-covered") && visible("back-visible")
        log.record("the window stack has both fixture windows, back-covered hidden and back-visible exposed", ok,
                   "Back #\(backID.raw) listed: \(ids.contains(backID)), Front #\(frontID.raw) listed: \(ids.contains(frontID))")
    }

    private struct Pressed {
        let name: String?
        let act: String?
        let detail: String
    }

    /// Shows hints, types the label of the fixture control `name`, and waits for the fixture to record a press.
    private func press(_ name: String, link: AppLink) async throws -> Pressed {
        let shown = try await link.press([.trigger], then: "showing")
        guard let target = hint(for: name, in: shown) else {
            _ = try await link.press([.escape], then: "idle")
            return Pressed(name: nil, act: nil, detail: "no hint for \(name)")
        }
        let before = fixture.presses.count
        _ = try await link.press([.letters(target.label)])
        let idle = try await link.waitFor(phase: "idle")
        let until = ContinuousClock.now + .milliseconds(1500)
        while fixture.presses.count == before, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(20))
        }
        let press = fixture.presses.count > before ? fixture.presses.last : nil
        let perform = idle.lastPerform
        let detail = [
            "label \(target.label)",
            "fixture recorded \(press.map { "\($0.name) active=\($0.appWasActive)" } ?? "nothing")",
            "plan \(perform?.plan ?? "-")",
            "act \(perform?.act ?? "-")",
            "frontmost before \(perform?.frontmostBefore.map(String.init) ?? "-") after \(perform?.frontmostAfter.map(String.init) ?? "-")",
        ].joined(separator: ", ")
        return Pressed(name: press?.name, act: perform?.act, detail: detail)
    }

    /// The hint of this process whose frame center lies inside the fixture control's frame.
    private func hint(for name: String, in s: SessionSnapshot) -> HintDump? {
        guard let frame = fixture.frame(of: name) else { return nil }
        return s.hints.first { h in
            let f = GlobalRect(x: h.frame.x, y: h.frame.y, width: h.frame.width, height: h.frame.height)
            return h.pid == Desktop.selfPID.raw && frame.contains(f.center)
        }
    }

    /// Makes es-dev a background app, so the next press shows whether the policy raised it first.
    /// The fixture windows float, so Finder's windows cannot cover them.
    private func moveActivationAway() {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        NSApp.yieldActivation(to: finder)
        finder.activate()
    }

    private func screencapture(_ url: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", url.path]
        guard (try? process.run()) != nil else { return false }
        while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        return process.terminationStatus == 0
    }

    private func save(_ snapshot: SessionSnapshot, as name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: outDirectory.appendingPathComponent(name), options: .atomic)
    }
}

private struct CheckLog {
    private(set) var total = 0
    private(set) var verified = 0

    mutating func record(_ name: String, _ ok: Bool, _ detail: String) {
        total += 1
        if ok { verified += 1 }
        print("\(ok ? "VERIFIED" : "NOT VERIFIED"): \(name). \(detail)")
    }

    @MainActor
    mutating func step(_ name: String, _ body: () async throws -> (Bool, String)) async {
        do {
            let (ok, detail) = try await body()
            record(name, ok, detail)
        } catch {
            record(name, false, "\(error)")
        }
    }
}

/// Request and reply with the app. Requests go over `DistributedNotificationCenter`, and the app
/// writes each reply atomically to a file named after the request id.
@MainActor
final class AppLink {
    enum Failure: Error, CustomStringConvertible {
        case noReply(AutomationCommand)
        case rejected(String)
        case phaseNotReached(String, last: String)

        var description: String {
            switch self {
            case .noReply(let command): "no reply to \(command)"
            case .rejected(let reason): "the app rejected the request: \(reason)"
            case .phaseNotReached(let phase, let last): "phase stayed \(last), expected \(phase)"
            }
        }
    }

    private let replyDirectory: URL

    init(replyDirectory: URL) {
        self.replyDirectory = replyDirectory
    }

    func send(_ command: AutomationCommand, timeout: Duration = .seconds(3)) async throws -> AutomationReply {
        let id = UUID().uuidString
        let replyURL = replyDirectory.appendingPathComponent("reply-\(id).json")
        let request = AutomationRequest(id: id, command: command, replyPath: replyURL.path)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        DistributedNotificationCenter.default().postNotificationName(
            AutomationChannel.command, object: nil, userInfo: [AutomationChannel.payloadKey: json], deliverImmediately: true
        )
        let until = ContinuousClock.now + timeout
        while ContinuousClock.now < until {
            if let data = try? Data(contentsOf: replyURL) {
                try? FileManager.default.removeItem(at: replyURL)
                return try JSONDecoder().decode(AutomationReply.self, from: data)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.noReply(command)
    }

    func status() async throws -> SessionSnapshot {
        try await send(.status).snapshot
    }

    /// Posts the inputs, then waits for `phase` when given.
    func press(_ inputs: [AutomationInput], then phase: String? = nil) async throws -> SessionSnapshot {
        let reply = try await send(.press(inputs))
        if let error = reply.error { throw Failure.rejected(error) }
        guard let phase else { return reply.snapshot }
        return try await waitFor(phase: phase)
    }

    func waitFor(phase: String, timeout: Duration = .seconds(2)) async throws -> SessionSnapshot {
        let until = ContinuousClock.now + timeout
        var last = try await status()
        while last.phase != phase, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(30))
            last = try await status()
        }
        guard last.phase == phase else { throw Failure.phaseNotReached(phase, last: last.phase) }
        return last
    }

    /// Retries until the app has started and answers.
    func waitForApp(timeout: Duration = .seconds(10)) async throws -> SessionSnapshot {
        let until = ContinuousClock.now + timeout
        while true {
            do {
                return try await send(.status, timeout: .seconds(1)).snapshot
            } catch where ContinuousClock.now < until {
                continue
            }
        }
    }
}
