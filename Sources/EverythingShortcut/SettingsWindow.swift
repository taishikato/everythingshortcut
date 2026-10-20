import AppKit
import ApplicationServices
import Badge
#if DEBUG
import Desktop
#endif
import HintCore
import ServiceManagement
import SwiftUI

/// The app's one window. It is first-run setup until setup was finished or skipped once, and Settings
/// after that, and either way it lists what still needs the user. AppKit owns the window, because the app
/// is `.accessory` and opens it from the status menu or a reopen. SwiftUI draws the grouped form inside it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: SettingsModel
    private let window: NSWindow
    private var trustWatch: Task<Void, Never>?
    private var occlusionObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    init(controller: HintController, statusItem: NSStatusItem) {
        model = SettingsModel(controller: controller, statusItem: statusItem)
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = .preferredContentSize
        window = NSWindow(contentViewController: hosting)
        super.init()
        window.styleMask = [.titled, .closable]
        // Opened from another Space or over a full-screen app, the window comes to the user's Space.
        // Without this, activating the app (a reopen, or a label press on one of its controls) switched
        // to the window's old Space, measured over a full-screen app, and the user lost the window.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        model.onComeForward = { [weak self] in self?.comeForward() }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followActiveSpace() }
        }
        model.onClose = { [weak self] in self?.window.performClose(nil) }
        // When launch opens this window, the status item's window may not have its occlusion state yet.
        if let itemWindow = statusItem.button?.window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: itemWindow, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refreshMenuBarIcon() }
            }
        }
    }

    /// The app is `.accessory`, which macOS never treats as the selected app: no Dock icon, no ⌘Tab entry,
    /// no menu bar. So the app is regular while the window is open and goes back to `.accessory` on close.
    func show() {
        model.refresh()
        window.title = model.guide.isComplete ? "Everything Shortcut Settings" : "Welcome to Everything Shortcut"
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        comeForward()
        watchTrust()
    }

    func refresh() { model.refresh() }

    func note(_ note: SessionNote) { model.note(note) }

    /// Activation is only a request, which macOS may refuse an agent app (cooperative activation),
    /// so the window is also ordered above the app the user is in.
    private func comeForward() {
        NSApp.activate()
        window.orderFrontRegardless()
    }

    /// Opening the app from a full-screen app's Space switches to a desktop Space after `show` ordered the
    /// window, which stayed behind on the full-screen Space (measured with a reopen). So while the app is active,
    /// a Space change brings the window along, and `moveToActiveSpace` moves it instead of switching back.
    private func followActiveSpace() {
        guard NSApp.isActive, window.isVisible, !window.isOnActiveSpace else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// No public API tells the app that Accessibility was turned on, so while the window is open without it,
    /// it reads the grant every 0.5 s and stops at the grant or on close.
    private func watchTrust() {
        guard trustWatch == nil, !model.guide.facts.trusted else { return }
        trustWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.model.refreshTrust()
                if self.model.guide.facts.trusted {
                    self.trustWatch = nil
                    return
                }
            }
        }
    }

    /// Accessibility and Login Items change in System Settings, so coming back reads them again.
    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
        watchTrust()
    }

    func windowDidResignKey(_ notification: Notification) { model.stopRecording() }

    /// Skip Setup, Done, Command-W and the close button all end here, and each one completes setup.
    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
        trustWatch?.cancel()
        trustWatch = nil
        model.dismissed()
        NSApp.setActivationPolicy(.accessory)
    }

    #if DEBUG
    /// For the automation hook: the window with the try step ready, as Try It opens it.
    func showPractice() {
        show()
        model.tryAgain()
    }

    /// Converted when asked, because the window may have moved since the view recorded the frame.
    var practiceDump: PracticeDump {
        let primaryHeight = Desktop.displays().primary?.bounds.height ?? 0
        func global(_ r: NSRect) -> GlobalRect { GlobalRect(AppKitRect(r), primaryDisplayHeight: primaryHeight) }
        var target: GlobalRect?
        if case .open = model.guide.practiceRow, let frame = model.practiceTargetFrame, let content = window.contentView {
            target = global(window.convertToScreen(content.convert(frame, to: nil)))
        }
        return PracticeDump(practice: model.guide.practice, target: target, window: window.isVisible ? global(window.frame) : nil)
    }
    #endif
}

/// The window's state. `guide` decides what the checklist shows.
/// A shortcut change goes through `apply`, which persists it and hands it to the reducer.
/// The reducer decides when it takes effect, and `refresh` redraws from the applied settings once it has.
@MainActor
@Observable
final class SettingsModel {
    private(set) var chord = ""
    private(set) var shortcut = ShortcutStatus.registered
    private(set) var triggerError = ""
    private(set) var isRecording = false
    private(set) var loginItem = SMAppService.Status.notRegistered
    private(set) var loginItemError = ""
    private(set) var guide: SetupGuide
    private(set) var menuBarIcon = MenuBarIcon.hidden

    @ObservationIgnored var onComeForward: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
    #if DEBUG
    /// The Click Me button in the hosting view's space, recorded by the view for the automation snapshot.
    @ObservationIgnored var practiceTargetFrame: CGRect?
    #endif

    @ObservationIgnored private let controller: HintController
    @ObservationIgnored private let statusItem: NSStatusItem
    @ObservationIgnored private let layout = KeyboardLayout()
    @ObservationIgnored private var monitor: Any?

    private static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }()

    init(controller: HintController, statusItem: NSStatusItem) {
        self.controller = controller
        self.statusItem = statusItem
        guide = SetupGuide(facts: Self.facts(of: controller), isComplete: SettingsStore.setupComplete)
        refresh()
    }

    /// The one place that reads the checklist's facts from macOS. AppDelegate's launch decision uses it too.
    static func facts(of controller: HintController) -> SetupFacts {
        SetupFacts(
            trusted: AXIsProcessTrusted(),
            shortcutWorks: HotKeyCenter.status(controller.triggerRegistration, for: controller.settings.trigger).works,
            trigger: controller.settings.trigger
        )
    }

    func refresh() {
        chord = layout.name(of: controller.settings.trigger)
        shortcut = HotKeyCenter.status(controller.triggerRegistration, for: controller.settings.trigger)
        loginItem = SMAppService.mainApp.status
        refreshMenuBarIcon()
        send(.refreshed(Self.facts(of: controller)))
    }

    /// The 0.5 s watch reads only the grant, and refreshes everything when it changed.
    func refreshTrust() {
        guard AXIsProcessTrusted() != guide.facts.trusted else { return }
        refresh()
    }

    /// Held while labels show: the overlay covers the status item, and the row must not move under them.
    func refreshMenuBarIcon() {
        guard case .idle = controller.phase else { return }
        menuBarIcon = Self.menuBarIcon(of: statusItem)
    }

    private static func menuBarIcon(of item: NSStatusItem) -> MenuBarIcon {
        guard let window = item.button?.window else { return .hidden }
        var notchGap: Range<Double>?
        if let left = window.screen?.auxiliaryTopLeftArea, let right = window.screen?.auxiliaryTopRightArea, left.maxX < right.minX {
            notchGap = Double(left.maxX)..<Double(right.minX)
        }
        return MenuBarIcon.judge(
            itemMinX: window.frame.minX, itemWidth: window.frame.width,
            notchGap: notchGap, windowVisible: window.occlusionState.contains(.visible)
        )
    }

    /// On while macOS has the login item, including while it waits for the user's approval.
    var launchesAtLogin: Bool {
        get { loginItem == .enabled || loginItem == .requiresApproval }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginItemError = ""
            } catch {
                loginItemError = error.localizedDescription
            }
            refresh()
        }
    }

    /// The one caller of the system prompt (scripts/check-invariants.sh enforces it). macOS shows the prompt
    /// only while it has no entry for the app, and the call creates that entry, so it always runs. From the
    /// second request on the prompt stays silent, so the pane opens as well.
    /// The key is the value of `kAXTrustedCheckOptionPrompt`, a C global that Swift 6 rejects as shared mutable state.
    func requestAccessibility() {
        let promptedBefore = SettingsStore.accessibilityPrompted
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if promptedBefore { NSWorkspace.shared.open(Self.accessibilityPane) }
        SettingsStore.accessibilityPrompted = true
        send(.askedForAccess)
    }

    /// The practice target's action. A label is being acted on exactly while the controller is performing,
    /// and our own probe presses on the main thread, so the action runs inside that press.
    func practiceTargetPressed() {
        let viaLabel = if case .performing = controller.phase { true } else { false }
        send(.targetPressed(viaLabel: viaLabel))
    }

    func tryAgain() { send(.tryAgain) }

    func note(_ note: SessionNote) { send(.session(note)) }

    /// Skip Setup and Done close the window, and closing is what completes setup.
    func finish() { onClose() }

    func dismissed() { send(.dismissed) }

    /// Opens the status item's menu, so the user sees where the icon is.
    func revealMenuBarIcon() {
        let button = statusItem.button
        // A press through a label runs this inside the press on the main thread, so the menu's tracking
        // loop starts a turn later, after the press returned.
        Task { button?.performClick(nil) }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    func restoreDefaults() {
        stopRecording()
        apply(.standard)
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    /// The key monitor sees keys only while the app is active, and a label press on the shortcut button
    /// does not activate the app (see `AppProbe.perform`), so recording waits for the app to be active.
    private func startRecording() {
        guard NSApp.isActive else {
            onComeForward()
            return
        }
        controller.suspendTrigger()
        triggerError = ""
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = Modifiers(event.modifierFlags)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                self.record(keyCode: keyCode, modifiers: modifiers)
                return true
            }
            return consumed ? nil : event
        }
        refresh()
    }

    private func record(keyCode: UInt16, modifiers: Modifiers) {
        if keyCode == VirtualKey.escape, modifiers.isEmpty {
            stopRecording()
            return
        }
        switch HotKey.validated(keyCode: keyCode, modifiers: modifiers) {
        case .failure(let error):
            triggerError = error.message
        case .success(let trigger):
            stopRecording()
            apply(UserSettings(trigger: trigger))
        }
    }

    /// Idempotent. Always gives the applied chord back to Carbon, so no path leaves the trigger suspended.
    func stopRecording() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        isRecording = false
        triggerError = ""
        controller.resumeTrigger()
        refresh()
    }

    private func apply(_ settings: UserSettings) {
        SettingsStore.save(settings)
        controller.configure(settings)
    }

    private func send(_ event: SetupEvent) {
        for effect in guide.send(event) {
            switch effect {
            case .persistComplete: SettingsStore.setupComplete = true
            case .comeForward: onComeForward()
            }
        }
    }
}

/// The badge's amber, so the window carries the same tone as the labels on screen.
@MainActor private var accent: Color { Color(nsColor: BadgeStyle.fillBottom) }

struct SettingsView: View {
    @Bindable var model: SettingsModel

    #if DEBUG
    /// The hosting view's own space. `.global` on macOS starts at the top of the window frame, title bar
    /// included, which put the recorded target 28 pt below the button (measured against its AX frame).
    nonisolated static let rootSpace = "settingsRoot"
    #endif

    var body: some View {
        VStack(spacing: 0) {
            form
            HStack {
                Spacer()
                if model.guide.isComplete {
                    Button("Restore Defaults", action: model.restoreDefaults)
                } else {
                    Button(model.guide.practice == .succeeded ? "Done" : "Skip Setup", action: model.finish)
                        .keyboardShortcut(model.guide.returnAction == .finish ? .defaultAction : nil)
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .tint(accent)
        #if DEBUG
        .coordinateSpace(.named(SettingsView.rootSpace))
        #endif
    }

    private var form: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AppIcon(size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Everything Shortcut").font(.title3.weight(.semibold))
                        Text("Click anything on screen from the keyboard.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.version).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                AccessRow(model: model)
                ShortcutRow(model: model)
                if let row = model.guide.practiceRow {
                    PracticeStepRow(model: model, row: row)
                }
            }

            Section {
                Toggle(isOn: $model.launchesAtLogin) {
                    Text("Launch at login")
                    if model.loginItem == .requiresApproval {
                        Text("Waiting for approval in System Settings > Login Items.")
                    }
                }
                .toggleStyle(.switch)
                if model.loginItem == .requiresApproval {
                    Button("Open Login Items…", action: model.openLoginItemsSettings)
                }
                if !model.loginItemError.isEmpty {
                    Text(model.loginItemError).foregroundStyle(.red)
                }
                MenuBarRow(model: model)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One checklist row: its mark, its title with a trailing status or control, and what it says below.
private struct StepRow<Trailing: View, Content: View>: View {
    let step: SetupStep
    let guide: SetupGuide
    let title: String
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StepMark(step: step, guide: guide)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.body.weight(.medium))
                    Spacer()
                    trailing
                }
                content
            }
        }
        .padding(.vertical, 2)
    }
}

/// A done step is a green check, the current step an amber number, a later step a gray number.
/// Never a yellow badge with a letter or number: on screen that means "type me", and the practice asks the
/// user to find exactly one.
private struct StepMark: View {
    let step: SetupStep
    let guide: SetupGuide

    var body: some View {
        let number = (SetupStep.allCases.firstIndex(of: step) ?? 0) + 1
        Group {
            if guide.isDone(step) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Done")
            } else {
                Image(systemName: "\(number).circle")
                    .foregroundStyle(guide.current == step ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    .accessibilityLabel("Step \(number)")
            }
        }
        .font(.title3)
    }
}

private struct AccessRow: View {
    let model: SettingsModel

    var body: some View {
        let guide = model.guide
        StepRow(step: .access, guide: guide, title: "Accessibility") {
            Text(guide.facts.trusted ? "Allowed" : guide.accessAsked ? "Waiting…" : "Not allowed")
                .foregroundStyle(.secondary)
        } content: {
            if !guide.facts.trusted {
                Text(guide.accessAsked
                    ? "Turn on Everything Shortcut in the list. This window moves on by itself. Already on? Turn it off and on again."
                    : "Everything Shortcut needs Accessibility to see buttons and click them for you. Nothing leaves your Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings", action: model.requestAccessibility)
                    .keyboardShortcut(guide.returnAction == .openSystemSettings ? .defaultAction : nil)
            }
        }
    }
}

private struct ShortcutRow: View {
    let model: SettingsModel

    var body: some View {
        let guide = model.guide
        StepRow(step: .shortcut, guide: guide, title: "Shortcut") {
            HStack {
                Button(action: model.toggleRecording) {
                    Text(model.isRecording ? "Type a shortcut…" : model.chord)
                        .font(.body.weight(.medium))
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(model.isRecording ? accent : nil)
                .keyboardShortcut(guide.returnAction == .recordShortcut ? .defaultAction : nil)
                if guide.practiceRow == nil {
                    Button("Try It", action: model.tryAgain).controlSize(.large)
                }
            }
        } content: {
            Text(model.isRecording ? "Press the new shortcut. Escape cancels." : "Press it in any app to show labels. Click to change.")
                .foregroundStyle(.secondary)
            if !model.triggerError.isEmpty {
                Text(model.triggerError).foregroundStyle(.red)
            } else if !model.isRecording, let problem = model.shortcut.problem(chord: model.chord) {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}

/// The hands-on step. Every open state draws the same views, and only the status slot's text changes,
/// in a slot that always holds two lines, so the target never moves under its label.
private struct PracticeStepRow: View {
    let model: SettingsModel
    let row: PracticeRow
    @State private var nudge = false

    var body: some View {
        StepRow(step: .practice, guide: model.guide, title: "Try it") {
            EmptyView()
        } content: {
            switch row {
            case .locked:
                Text("After the steps above.").foregroundStyle(.secondary)
            case .open(let practice):
                Text("Press \(model.chord). Then type the yellow label on Click Me.").foregroundStyle(.secondary)
                Button(action: model.practiceTargetPressed) {
                    Group {
                        if practice == .succeeded {
                            Label("Clicked", systemImage: "checkmark")
                        } else {
                            Text("Click Me")
                        }
                    }
                    .frame(minWidth: 160)
                }
                .controlSize(.large)
                .disabled(practice == .succeeded)
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SettingsView.rootSpace)) } action: { model.practiceTargetFrame = $0 }
                #endif
                .padding(.vertical, 6)
                Text(status(practice))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .task(id: practice) {
                        nudge = false
                        guard practice == .ready else { return }
                        try? await Task.sleep(for: .seconds(8))
                        if !Task.isCancelled { nudge = true }
                    }
            }
        }
        .opacity(row == .locked ? 0.5 : 1)
    }

    private func status(_ practice: Practice) -> String {
        let chord = model.chord
        return switch practice {
        case .idle, .labelsOpen: ""
        // After 8 s with no trigger at all, the likely cause is a chord another app holds, which no API reports.
        case .ready: nudge ? "Nothing happening? Another app may use \(chord).\nPick another shortcut above." : ""
        case .missed(.closed): "Labels closed. Press \(chord) to try again."
        case .missed(.elsewhere): "That label clicked something else. Try the one on Click Me."
        case .missed(.withoutLabel): "Clicked without a label. Press \(chord) first."
        case .secureInput: "Secure input is on, so labels can't open.\nLeave the password field or turn off Secure Keyboard Entry."
        case .succeeded: "That's it. Labels work the same in every app, the menu bar and the Dock."
        }
    }
}

/// Where to find the app again. Reopening the app always works, so both states teach it.
private struct MenuBarRow: View {
    let model: SettingsModel

    var body: some View {
        let visible = model.menuBarIcon == .visible
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Menu bar icon")
                Spacer()
                if visible {
                    Button("Show Me", action: model.revealMenuBarIcon)
                } else {
                    Text("Hidden").foregroundStyle(.secondary)
                }
            }
            Group {
                if visible {
                    // Text sets the 18 pt image on the baseline with its label mid-box, so 4 pt lower centers the label on the capitals.
                    Text("Everything Shortcut lives in the menu bar as \(Text(Image(nsImage: .statusItemIcon).renderingMode(.template)).baselineOffset(-4)). Opening the app again also brings you here.")
                } else {
                    Text("The menu bar is full, so macOS hides the icon. Open Everything Shortcut again, from Spotlight for example, to come back here.")
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var m: Modifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        self = m
    }
}
