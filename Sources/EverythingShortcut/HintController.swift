import AppKit
import ApplicationServices
import Carbon
import Desktop
import HintCore
import os

/// The single owner of hint-session state.
///
/// Every input (hotkey, tap keystroke, mouse-down, scan result, perform completion) becomes an `Event`.
/// `HintMachine` decides. This class runs the returned effects against its adapters, in order,
/// and makes no decision of its own. Reading this file plus `HintMachine.swift` and `Scan.swift`
/// traces a hotkey press all the way to the click.
@MainActor
final class HintController {
    private var config: HintConfig
    private var machine: HintMachine<ElementRef>
    private let hotKey: HotKeyCenter
    private let keys: KeyCapture
    private let overlay = Overlay()
    private let notice = Notice()
    private let scanner: Scanner
    private var scanTask: Task<Void, Never>?
    private var pending: [Event<ElementRef>] = []
    private var draining = false
    private let log = Logger(subsystem: "com.taishikato.EverythingShortcut", category: "session")

    /// Whether the trigger chord is ours. A chord held by another app leaves the menu as the entry point.
    /// A failed chord stays chosen and persisted, so the user sees the failure instead of a silent revert.
    private(set) var triggerRegistration: HotKeyCenter.Registration

    /// Runs after new settings took effect, so the settings window can redraw.
    var onSettingsApplied: () -> Void = {}

    /// Runs when a trigger was refused for lack of Accessibility.
    var onNeedsAccessibility: () -> Void = {}

    /// Diagnostics for the log and the DEBUG automation snapshot. Not session state.
    private(set) var lastScanStats: ScanStats?
    private(set) var lastPerform: PerformReport?

    init(config: HintConfig) {
        self.config = config
        machine = HintMachine(alphabet: config.alphabet)
        keys = KeyCapture(trigger: config.trigger, alphabet: config.alphabet)
        scanner = Scanner(config: config)
        let hotKey = HotKeyCenter()
        self.hotKey = hotKey
        triggerRegistration = hotKey.register(config.trigger)
        keys.onKey = { [weak self] in self?.send(.key($0)) }
        keys.onMouseDown = { [weak self] in self?.send(.mouseDown) }
        keys.onLost = { [weak self] in self?.send(.keyCaptureLost) }
        hotKey.onPress = { [weak self] in self?.triggerPressed() }
    }

    var phase: Phase<ElementRef> { machine.phase }
    /// The applied settings. A configure sent mid-session is not here until the session ends.
    var settings: UserSettings { config.settings }
    var overlayPanelFrames: [AppKitRect] { overlay.panelFrames }

    /// The hotkey and the status item menu both land here.
    func triggerPressed() {
        send(.trigger(Self.gate()))
    }

    func configure(_ settings: UserSettings) {
        send(.configure(settings))
    }

    /// Carbon fires a registered chord even while our own window is key, so recording a new chord
    /// in Settings must release the current one first.
    func suspendTrigger() {
        hotKey.unregister()
    }

    func resumeTrigger() {
        triggerRegistration = hotKey.register(config.trigger)
    }

    /// Run to completion. Events raised while effects run (a failed tap enable, a synchronous
    /// callback) queue behind the current one instead of re-entering the reducer.
    func send(_ event: Event<ElementRef>) {
        pending.append(event)
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !pending.isEmpty {
            let next = pending.removeFirst()
            for effect in machine.send(next) { run(effect) }
        }
    }

    private func run(_ effect: Effect<ElementRef>) {
        switch effect {
        case .startScan(let id):
            let running = Desktop.runningApps()
            let scanner = scanner
            scanTask = Task { [weak self] in
                let report = await scanner.scan(running)
                guard let self else { return }
                let stats = report.stats
                self.log.info("scan \(id.raw): \(stats.candidates) hints from \(stats.apps.count) apps, \(stats.nodesRead) nodes, \(String(describing: stats.duration), privacy: .public)")
                if case .scanning(id) = self.machine.phase { self.lastScanStats = stats }
                self.send(.scanned(id, report.candidates))   // the reducer alone decides whether it is stale
            }

        case .cancelScan:
            scanTask?.cancel()
            scanTask = nil

        case .captureKeys(let on):
            if !keys.setActive(on) { send(.keyCaptureLost) }

        case .render(let board):
            let displays = Desktop.displays()
            overlay.render(
                board.map { BadgeLayout.layout($0, displays: displays) } ?? [],
                primaryDisplayHeight: displays.primary?.bounds.height ?? 0
            )

        case .perform(let target):
            Task { [weak self] in
                let report = await target.perform()
                guard let self else { return }
                self.lastPerform = report
                self.log.info("perform pid \(report.pid.raw): \(String(describing: report.plan), privacy: .public), \(String(describing: report.act), privacy: .public)")
                self.send(.performed)
            }

        case .alert(let alert):
            report(alert)

        case .applySettings(let settings):
            triggerRegistration = hotKey.register(settings.trigger)
            keys.trigger = settings.trigger
            config = config.applying(settings)
            onSettingsApplied()
        }
    }

    /// Facts the reducer needs to accept a trigger. Both are cheap local calls.
    private static func gate() -> TriggerGate {
        if !AXIsProcessTrusted() { return .blocked(.needsAccessibility) }
        if secureInputActive { return .blocked(.secureInputActive) }
        return .ready
    }

    /// Secure Event Input, read in one place. The gate refuses a trigger on it, and the status menu says so.
    /// The app that holds it is never named: the only source (`kCGSSessionSecureInputPID`) names the
    /// frontmost app instead (measured with a CLI process holding it while Chrome was frontmost).
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    private func report(_ alert: Alert) {
        log.notice("alert \(String(describing: alert), privacy: .public)")
        switch alert {
        case .needsAccessibility:
            onNeedsAccessibility()
        case .secureInputActive:
            NSSound.beep()
            notice.show("Labels can't open while a password field or Secure Keyboard Entry is on.")
        case .noHints, .noMatch, .keyCaptureLost:
            NSSound.beep()
        }
    }
}
