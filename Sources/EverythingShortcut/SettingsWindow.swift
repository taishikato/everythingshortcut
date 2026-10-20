import AppKit
import Carbon
import HintCore

/// The one Settings window: the trigger chord and the label alphabet.
/// Every change goes through `apply`, which persists it and hands it to the reducer. The reducer decides
/// when it takes effect, and `refresh` redraws from the controller's applied settings once it has.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let controller: HintController
    private let layout = KeyboardLayout()
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private let recorder = NSButton(title: "", target: nil, action: nil)
    private let triggerStatus = NSTextField(labelWithString: "")
    private let triggerError = NSTextField(labelWithString: "")
    private let alphabetField = NSTextField(string: "")
    private let alphabetError = NSTextField(labelWithString: "")
    /// Non-nil exactly while a chord is being recorded.
    private var recordingMonitor: Any?

    init(controller: HintController) {
        self.controller = controller
        super.init()
        window.title = "Everything Shortcut Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        recorder.target = self
        recorder.action = #selector(toggleRecording)
        alphabetField.delegate = self
        triggerStatus.textColor = .secondaryLabelColor
        triggerError.textColor = .systemRed
        alphabetError.textColor = .systemRed
        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))

        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Trigger:"), recorder],
            [empty, triggerStatus],
            [empty, triggerError],
            [NSTextField(labelWithString: "Labels:"), alphabetField],
            [empty, alphabetError],
            [empty, restore],
        ])
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 5).topPadding = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            alphabetField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        window.contentView = content
        refresh()
        window.center()
    }

    /// The app is `.accessory`, so the window only takes keys after the app activates.
    func show() {
        refresh()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Redraws from the applied settings. Called on show and after every apply.
    /// An alphabet edit in progress is kept, so recording a chord mid-edit does not discard it.
    func refresh() {
        refreshTrigger()
        guard alphabetField.currentEditor() == nil else { return }
        showAlphabet(controller.settings.alphabet)
    }

    private func showAlphabet(_ alphabet: Alphabet) {
        alphabetField.stringValue = alphabet.string
        alphabetError.stringValue = ""
    }

    /// Leaves the alphabet field alone, so starting or stopping a recording keeps an unfinished edit.
    private func refreshTrigger() {
        let chord = layout.name(of: controller.settings.trigger)
        recorder.title = isRecording ? "Type a shortcut…" : chord
        triggerStatus.stringValue = switch controller.triggerRegistration {
        case .registered: "Registered"
        case .failed(let status) where status == eventHotKeyExistsErr: "Not registered, another app holds \(chord)"
        case .failed(let status): "Not registered (error \(status))"
        }
    }

    private func apply(_ settings: UserSettings) {
        SettingsStore.save(settings)
        controller.configure(settings)
    }

    @objc private func restoreDefaults() {
        stopRecording()
        alphabetField.abortEditing()
        showAlphabet(UserSettings.standard.alphabet)
        apply(.standard)
    }

    private var isRecording: Bool { recordingMonitor != nil }

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        controller.suspendTrigger()
        triggerError.stringValue = ""
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = Modifiers(event.modifierFlags)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                self.record(keyCode: keyCode, modifiers: modifiers)
                return true
            }
            return consumed ? nil : event
        }
        refreshTrigger()
    }

    private func record(keyCode: UInt16, modifiers: Modifiers) {
        if keyCode == VirtualKey.escape, modifiers.isEmpty {
            stopRecording()
            return
        }
        switch HotKey.validated(keyCode: keyCode, modifiers: modifiers) {
        case .failure(let error):
            triggerError.stringValue = error.message
        case .success(let trigger):
            stopRecording()
            apply(UserSettings(trigger: trigger, alphabet: controller.settings.alphabet))
        }
    }

    /// Idempotent. Always gives the applied chord back to Carbon, so no path leaves the trigger suspended.
    private func stopRecording() {
        guard let recordingMonitor else { return }
        NSEvent.removeMonitor(recordingMonitor)
        self.recordingMonitor = nil
        triggerError.stringValue = ""
        controller.resumeTrigger()
        refreshTrigger()
    }

    func windowDidResignKey(_ notification: Notification) {
        stopRecording()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        window.makeFirstResponder(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        alphabetError.stringValue = switch Alphabet.parse(alphabetField.stringValue) {
        case .success: ""
        case .failure(let error): error.message
        }
    }

    /// Return, Tab, a click elsewhere, or closing the window. Invalid text stays for the user to fix.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard case .success(let alphabet) = Alphabet.parse(alphabetField.stringValue) else { return }
        alphabetField.stringValue = alphabet.string
        let next = UserSettings(trigger: controller.settings.trigger, alphabet: alphabet)
        if next != controller.settings { apply(next) }
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
