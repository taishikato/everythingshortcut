import AppKit
import ApplicationServices
import Carbon
import HintCore
#if DEBUG
import AutomationWire
#endif

/// Process wiring. Reads `HintConfig.standard` once and hands it to the controller.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let config = HintConfig.standard
    private var controller: HintController?
    private var statusItem: NSStatusItem?
    #if DEBUG
    private var automation: AutomationServer?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        Scanner.setProcessMessagingTimeout(config.axMessagingTimeout)
        if !AXIsProcessTrusted() { HintController.promptForAccessibility() }

        let controller = HintController(config: config)
        self.controller = controller
        statusItem = makeStatusItem()

        #if DEBUG
        assert(CGWindowLevelForKey(.dockWindow) == Int32(WindowLayer.dock))
        assert(CGWindowLevelForKey(.mainMenuWindow) == Int32(WindowLayer.mainMenu))
        assert(CGWindowLevelForKey(.statusWindow) == Int32(WindowLayer.status))
        if CommandLine.arguments.contains(AutomationChannel.launchArgument) {
            let server = AutomationServer(controller: controller, trigger: config.trigger)
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

    /// Rebuilt on every open, so the Accessibility line is never stale after the user grants it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let chord = config.trigger.displayName

        menu.addItem(info(AXIsProcessTrusted() ? "Accessibility: granted" : "Accessibility: not granted"))
        menu.addItem(action("Open Accessibility Settings…", #selector(openAccessibilitySettings)))
        menu.addItem(.separator())
        switch controller?.triggerRegistration {
        case .registered:
            menu.addItem(info("Trigger \(chord): registered"))
        case .failed(let status) where status == eventHotKeyExistsErr:
            menu.addItem(info("Trigger \(chord): not registered, another app holds it"))
        case .failed(let status):
            menu.addItem(info("Trigger \(chord): not registered (error \(status))"))
        case nil:
            break
        }
        menu.addItem(action("Show hints", #selector(showHints)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Everything Shortcut", #selector(NSApplication.terminate(_:)), target: NSApp, key: "q"))
    }

    @objc private func showHints() {
        controller?.triggerPressed()
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
