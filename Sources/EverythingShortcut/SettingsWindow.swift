import AppKit
import ApplicationServices
import HintCore
import ServiceManagement
import SwiftUI

/// The one Settings window: the app card, the shortcut that shows hints, and the app's status.
/// AppKit owns the window, because the app is `.accessory` and opens it from the status menu.
/// SwiftUI draws the grouped form inside it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: SettingsModel
    private let window: NSWindow

    init(controller: HintController) {
        model = SettingsModel(controller: controller)
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = .preferredContentSize
        window = NSWindow(contentViewController: hosting)
        super.init()
        window.title = "Everything Shortcut Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    /// The app is `.accessory`, so the window only takes keys after the app activates.
    func show() {
        model.refresh()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func refresh() { model.refresh() }

    /// Accessibility and Login Items change in System Settings, so coming back reads them again.
    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }

    func windowDidResignKey(_ notification: Notification) { model.stopRecording() }

    func windowWillClose(_ notification: Notification) { model.stopRecording() }
}

/// Settings state. A shortcut change goes through `apply`, which persists it and hands it to the reducer.
/// The reducer decides when it takes effect, and `refresh` redraws from the applied settings once it has.
@MainActor
@Observable
final class SettingsModel {
    private(set) var chord = ""
    private(set) var shortcut = (text: "", works: true)
    private(set) var triggerError = ""
    private(set) var isRecording = false
    private(set) var accessibilityGranted = false
    private(set) var loginItem = SMAppService.Status.notRegistered
    private(set) var loginItemError = ""

    @ObservationIgnored private let controller: HintController
    @ObservationIgnored private let layout = KeyboardLayout()
    @ObservationIgnored private var monitor: Any?

    let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }()

    init(controller: HintController) {
        self.controller = controller
        refresh()
    }

    func refresh() {
        chord = layout.name(of: controller.settings.trigger)
        shortcut = HotKeyCenter.status(controller.triggerRegistration, for: controller.settings.trigger)
        accessibilityGranted = AXIsProcessTrusted()
        loginItem = SMAppService.mainApp.status
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

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    func restoreDefaults() {
        stopRecording()
        apply(.standard)
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
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
}

/// The badge's amber, so Settings carries the same tone as the hints on screen.
@MainActor private var accent: Color { Color(nsColor: BadgeStyle.fillBottom) }

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            form
            HStack {
                Spacer()
                Button("Restore Defaults", action: model.restoreDefaults)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .tint(accent)
    }

    private var form: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AppIcon()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Everything Shortcut").font(.title3.weight(.semibold))
                        Text("Click anything on screen from the keyboard.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.version).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Shortcut") {
                LabeledContent {
                    Button(action: model.toggleRecording) {
                        Text(model.isRecording ? "Type a shortcut…" : model.chord)
                            .font(.body.weight(.medium))
                            .frame(minWidth: 120)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                    .tint(model.isRecording ? accent : nil)
                } label: {
                    Text("Show hints")
                    Text("Click, then press the new shortcut. Escape cancels.")
                }
                if !model.triggerError.isEmpty {
                    Text(model.triggerError).foregroundStyle(.red)
                } else if !model.isRecording && !model.shortcut.works {
                    Label(sentence(model.shortcut.text), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            Section("Status") {
                LabeledContent("Accessibility") {
                    if model.accessibilityGranted {
                        StatusDot(text: "Granted", color: .green)
                    } else {
                        HStack {
                            StatusDot(text: "Not granted", color: .orange)
                            Button("Open Settings…", action: model.openAccessibilitySettings)
                        }
                    }
                }
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
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
}

private struct StatusDot: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// A yellow badge with a keyboard, drawn like the hints on screen. The app bundle has no icon file.
private struct AppIcon: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Image(systemName: "keyboard")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color(nsColor: BadgeStyle.text))
            .frame(width: 40, height: 40)
            .background(LinearGradient(colors: [Color(nsColor: BadgeStyle.fillTop), Color(nsColor: BadgeStyle.fillBottom)], startPoint: .top, endPoint: .bottom), in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: BadgeStyle.border), lineWidth: 1))
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
