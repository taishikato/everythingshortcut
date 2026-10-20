import AppKit
import HintCore
import SwiftUI

/// The one Settings window: the shortcut that shows hints, and the letters badges are spelled with.
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
        window.title = "Everything Shortcut"
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

    func windowDidResignKey(_ notification: Notification) { model.stopRecording() }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
        model.commitLetters()
    }
}

/// Settings state. Every change goes through `apply`, which persists it and hands it to the reducer.
/// The reducer decides when it takes effect, and `refresh` redraws from the applied settings once it has.
@MainActor
@Observable
final class SettingsModel {
    /// Badges in the preview when no scan has run yet. Real desktops measured 160 to 185.
    static let typicalBadgeCount = 150

    private(set) var chord = ""
    private(set) var status = (text: "", works: true)
    private(set) var triggerError = ""
    private(set) var isRecording = false
    var letters = ""

    @ObservationIgnored private let controller: HintController
    @ObservationIgnored private let layout = KeyboardLayout()
    @ObservationIgnored private var monitor: Any?

    init(controller: HintController) {
        self.controller = controller
        refresh()
    }

    /// The letters as typed, parsed. The preview and the error line both read it, so they never disagree.
    var parsedLetters: Result<Alphabet, AlphabetError> { Alphabet.parse(letters) }

    /// The last scan's badge count, so the preview matches what the user just saw.
    var previewCount: Int { controller.lastScanStats?.candidates ?? Self.typicalBadgeCount }

    /// The applied alphabet the field last showed. While the field still shows it, the field follows
    /// the applied settings. Once the user edits it, the edit stays, so recording a shortcut mid-edit
    /// does not discard it.
    @ObservationIgnored private var shownAlphabet = ""

    func refresh() {
        chord = layout.name(of: controller.settings.trigger)
        let current = HotKeyCenter.status(controller.triggerRegistration, for: controller.settings.trigger)
        status = isRecording ? ("paused while you type a new shortcut", true) : current
        let applied = controller.settings.alphabet.string
        if letters == shownAlphabet { letters = applied }
        shownAlphabet = applied
    }

    func commitLetters() {
        guard case .success(let alphabet) = parsedLetters else { return }
        letters = alphabet.string
        let next = UserSettings(trigger: controller.settings.trigger, alphabet: alphabet)
        if next != controller.settings { apply(next) }
    }

    func restoreDefaults() {
        stopRecording()
        letters = shownAlphabet
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
            apply(UserSettings(trigger: trigger, alphabet: controller.settings.alphabet))
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

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @FocusState private var lettersFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            form
            HStack {
                Spacer()
                Button("Restore Defaults", action: model.restoreDefaults)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent("Show hints") {
                    Button(action: model.toggleRecording) {
                        Text(model.isRecording ? "Type a shortcut…" : model.chord)
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .frame(minWidth: 120)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                    .tint(model.isRecording ? .accentColor : nil)
                }
                if !model.triggerError.isEmpty {
                    Text(model.triggerError).foregroundStyle(.red).font(.callout)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Label(model.status.text.prefix(1).uppercased() + model.status.text.dropFirst(),
                      systemImage: model.status.works ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.status.works ? Color.secondary : Color.orange)
                    .font(.callout)
            }

            Section {
                TextField("Letters", text: $model.letters)
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .focused($lettersFocused)
                    .onSubmit(model.commitLetters)
                    .onChange(of: lettersFocused) { _, focused in if !focused { model.commitLetters() } }
                switch model.parsedLetters {
                case .success(let alphabet): BadgePreview(alphabet: alphabet, count: model.previewCount)
                case .failure(let error): Text(error.message).foregroundStyle(.red).font(.callout)
                }
            } header: {
                Text("Badge letters")
            } footer: {
                Text("Badges are spelled with these letters. Fewer letters make longer badges to type. The first letters start the most badges, so put the easiest keys first.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The badges this alphabet would draw on a screen with `count` clickable things, in the overlay's style.
struct BadgePreview: View {
    let alphabet: Alphabet
    let count: Int

    var body: some View {
        let labels = LabelGenerator.labels(count: count, alphabet: alphabet)
        let longest = labels.map(\.count).max() ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(labels.prefix(5).enumerated()), id: \.offset) { Badge(text: $0.element) }
                Text("…").foregroundStyle(.secondary)
                ForEach(Array(labels.suffix(3).enumerated()), id: \.offset) { Badge(text: $0.element) }
            }
            Text("With \(count) badges on screen, the longest takes \(longest) \(longest == 1 ? "key" : "keys") to type.")
                .foregroundStyle(longest > 2 ? Color.orange : Color.secondary)
                .font(.callout)
        }
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BadgeStyle.cornerRadius)
        Text(text.uppercased())
            .font(Font(BadgeStyle.font))
            .foregroundStyle(Color(nsColor: BadgeStyle.text))
            .padding(.horizontal, BadgeStyle.padding.width)
            .padding(.vertical, BadgeStyle.padding.height)
            .background(LinearGradient(colors: [Color(nsColor: BadgeStyle.fillTop), Color(nsColor: BadgeStyle.fillBottom)], startPoint: .top, endPoint: .bottom), in: shape)
            .overlay(shape.stroke(Color(nsColor: BadgeStyle.border)))
            .shadow(color: Color(nsColor: BadgeStyle.shadow), radius: 1.5, y: 1)
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
