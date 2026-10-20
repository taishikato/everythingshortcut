import AppKit
import ApplicationServices
import Carbon
import HintCore
#if DEBUG
import AutomationWire
#endif

/// Process wiring. Builds the config once from `HintConfig.standard` and the persisted settings,
/// and hands it to the controller. After launch, the trigger is read only from `controller.settings`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: HintController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController?
    private let layout = KeyboardLayout()
    #if DEBUG
    private var automation: AutomationServer?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = HintConfig.standard.applying(SettingsStore.load())
        Scanner.setProcessMessagingTimeout(config.axMessagingTimeout)
        if !AXIsProcessTrusted() { HintController.promptForAccessibility() }

        let controller = HintController(config: config)
        controller.onSettingsApplied = { [weak self] in self?.settingsWindow?.refresh() }
        self.controller = controller
        statusItem = makeStatusItem()
        NSApp.mainMenu = Self.editMenu()

        #if DEBUG
        assert(CGWindowLevelForKey(.dockWindow) == Int32(WindowLayer.dock))
        assert(CGWindowLevelForKey(.mainMenuWindow) == Int32(WindowLayer.mainMenu))
        assert(CGWindowLevelForKey(.statusWindow) == Int32(WindowLayer.status))
        if CommandLine.arguments.contains(AutomationChannel.launchArgument) {
            let server = AutomationServer(controller: controller)
            server.start()
            automation = server
        }
        #endif
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Everything Shortcut")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        return item
    }

    /// Rebuilt on every open, so the Accessibility and trigger lines are never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller else { return }
        let chord = layout.name(of: controller.settings.trigger)

        menu.addItem(info(AXIsProcessTrusted() ? "Accessibility: granted" : "Accessibility: not granted"))
        menu.addItem(action("Open Accessibility Settings…", #selector(openAccessibilitySettings)))
        menu.addItem(.separator())
        switch controller.triggerRegistration {
        case .registered:
            menu.addItem(info("Trigger \(chord): registered"))
        case .failed(let status) where status == eventHotKeyExistsErr:
            menu.addItem(info("Trigger \(chord): not registered, another app holds it"))
        case .failed(let status):
            menu.addItem(info("Trigger \(chord): not registered (error \(status))"))
        }
        menu.addItem(action("Show hints", #selector(showHints)))
        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("Quit Everything Shortcut", #selector(NSApplication.terminate(_:)), target: NSApp, key: "q"))
    }

    @objc private func showHints() {
        controller?.triggerPressed()
    }

    /// An accessory app shows no menu bar, but text fields still get Cut, Copy, Paste and Undo
    /// only through the main menu's key equivalents.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        return main
    }

    @objc private func openSettings() {
        guard let controller else { return }
        let window = settingsWindow ?? SettingsWindowController(controller: controller)
        settingsWindow = window
        window.show()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, target: AnyObject? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target ?? self
        return item
    }
}
