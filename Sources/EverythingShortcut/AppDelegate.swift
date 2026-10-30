import AppKit
import ApplicationServices
import Badge
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

        let controller = HintController(config: config)
        controller.onSettingsApplied = { [weak self] in self?.settingsWindow?.refresh() }
        // In place of the system prompt, which macOS shows only once anyway.
        controller.onNeedsAccessibility = { [weak self] in self?.openSettings() }
        self.controller = controller
        statusItem = makeStatusItem()
        NSApp.mainMenu = mainMenu()

        let guide = SetupGuide(facts: SettingsModel.facts(of: controller), isComplete: SettingsStore.setupComplete)
        if !launchedForAutomation, guide.opensAtLaunch { openSettings() }

        #if DEBUG
        assert(CGWindowLevelForKey(.dockWindow) == Int32(WindowLayer.dock))
        assert(CGWindowLevelForKey(.mainMenuWindow) == Int32(WindowLayer.mainMenu))
        assert(CGWindowLevelForKey(.statusWindow) == Int32(WindowLayer.status))
        assert(CGWindowLevelForKey(.screenSaverWindow) == Int32(WindowLayer.overlay))
        assert(NSWindow.Level.screenSaver.rawValue == WindowLayer.overlay)
        if launchedForAutomation {
            let server = AutomationServer(controller: controller, window: WindowHook(
                open: { [weak self] in self?.openSettings() },
                frame: { [weak self] in self?.settingsWindow?.windowFrame }
            ))
            server.start()
            automation = server
        }
        #endif
    }

    /// A launch for automation is never a first run, so the e2e run starts with no window of ours on screen.
    private var launchedForAutomation: Bool {
        #if DEBUG
        CommandLine.arguments.contains(AutomationChannel.launchArgument)
        #else
        false
        #endif
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = .statusItemIcon
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        return item
    }

    /// Rebuilt on every open, so the Accessibility, shortcut and secure input lines are never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller else { return }
        let chord = layout.name(of: controller.settings.trigger)

        menu.addItem(AXIsProcessTrusted() ? info("Accessibility: allowed") : action("Allow Accessibility…", #selector(openSettings)))
        menu.addItem(info("Shortcut \(chord): \(HotKeyCenter.status(controller.triggerRegistration, for: controller.settings.trigger).menuText)"))
        if HintController.secureInputActive { menu.addItem(info("Labels paused: secure input is on")) }
        menu.addItem(action("Show Labels", #selector(showHints)))
        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("Quit Everything Shortcut", #selector(NSApplication.terminate(_:)), target: NSApp, key: "q"))
    }

    @objc private func showHints() {
        controller?.triggerPressed()
    }

    /// Opening the app again while it runs shows the window. The status item is the only other way in,
    /// and macOS hides status items behind the notch when the menu bar is full.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// Shown only while the window makes the app a regular app, so ⌘, ⌘W, ⌘H and ⌘Q work as in any app.
    private func mainMenu() -> NSMenu {
        let app = NSMenu()
        app.addItem(action("Settings…", #selector(openSettings), key: ","))
        app.addItem(.separator())
        app.addItem(action("Hide Everything Shortcut", #selector(NSApplication.hide(_:)), target: NSApp, key: "h"))
        app.addItem(.separator())
        app.addItem(action("Quit Everything Shortcut", #selector(NSApplication.terminate(_:)), target: NSApp, key: "q"))
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu()
        for (title, submenu) in [("Everything Shortcut", app), ("Window", window)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }

    @objc private func openSettings() {
        settingsWindowController()?.show()
    }

    private func settingsWindowController() -> SettingsWindowController? {
        guard let controller, let statusItem else { return nil }
        let window = settingsWindow ?? SettingsWindowController(controller: controller, statusItem: statusItem)
        settingsWindow = window
        return window
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
