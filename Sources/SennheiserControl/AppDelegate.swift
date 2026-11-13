import AppKit
import SwiftUI
import Combine
import GAIA3

enum Preference {
    static let showInMenuBar = "showInMenuBar"
    static let showFrameLog = "showFrameLog"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let session: HeadphoneSession
    private let defaults = UserDefaults.standard
    private var window: NSWindow!
    private var statusItem: StatusItemController!

    init(session: HeadphoneSession) {
        self.session = session
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [Preference.showInMenuBar: true])
        NSApp.mainMenu = makeMainMenu()

        window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(session: session)))
        window.title = "Sennheiser Control"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = Palette.groundColor
        window.setContentSize(NSSize(width: 940, height: 800))
        window.center()
        window.setFrameAutosaveName("MainWindow")

        statusItem = StatusItemController(session: session) { [weak self] in self?.showWindow(nil) }
        statusItem.isVisible = defaults.bool(forKey: Preference.showInMenuBar)
        if CommandLine.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.statusItem.showPanel() }
        }

        showWindow(nil)
        session.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !statusItem.isVisible
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Actions

    @objc func showWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleConnection(_ sender: Any?) {
        if session.isConnected || session.isConnecting {
            session.disconnect()
        } else if !session.connectPreferred() {
            showWindow(nil)
        }
    }

    @objc func refreshState(_ sender: Any?) {
        session.refreshAll()
    }

    @objc func selectNoiseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = NoiseControl.Mode(rawValue: raw) else { return }
        session.setNoiseMode(mode)
    }

    @objc func toggleAutoConnect(_ sender: Any?) {
        session.autoConnect.toggle()
    }

    @objc func toggleFrameLog(_ sender: Any?) {
        defaults.set(!defaults.bool(forKey: Preference.showFrameLog), forKey: Preference.showFrameLog)
    }

    @objc func toggleMenuBarItem(_ sender: Any?) {
        statusItem.isVisible.toggle()
        defaults.set(statusItem.isVisible, forKey: Preference.showInMenuBar)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleConnection(_:)):
            menuItem.title = session.isConnected || session.isConnecting ? "Disconnect" : "Connect"
        case #selector(refreshState(_:)):
            return session.isConnected
        case #selector(selectNoiseMode(_:)):
            menuItem.state = (menuItem.representedObject as? String) == session.device.noise.activeMode?.rawValue ? .on : .off
            return session.isConnected
        case #selector(toggleAutoConnect(_:)):
            menuItem.state = session.autoConnect ? .on : .off
        case #selector(toggleFrameLog(_:)):
            menuItem.state = defaults.bool(forKey: Preference.showFrameLog) ? .on : .off
        case #selector(toggleMenuBarItem(_:)):
            menuItem.state = statusItem.isVisible ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: - Main menu

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(item("About Sennheiser Control", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        app.addItem(.separator())
        app.addItem(item("Show in Menu Bar", #selector(toggleMenuBarItem(_:))))
        app.addItem(.separator())
        app.addItem(item("Hide Sennheiser Control", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                         modifiers: [.command, .option], target: NSApp))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        app.addItem(.separator())
        app.addItem(item("Quit Sennheiser Control", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        add(app, titled: "Sennheiser Control", to: main)

        let edit = NSMenu()
        edit.addItem(item("Undo", Selector(("undo:")), "z", target: nil))
        edit.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift], target: nil))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x", target: nil))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c", target: nil))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v", target: nil))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a", target: nil))
        add(edit, titled: "Edit", to: main)

        let device = NSMenu()
        device.addItem(item("Connect", #selector(toggleConnection(_:)), "k"))
        device.addItem(item("Refresh", #selector(refreshState(_:)), "r"))
        device.addItem(.separator())
        for (index, mode) in NoiseControl.Mode.allCases.enumerated() {
            let entry = item(mode.menuTitle, #selector(selectNoiseMode(_:)), "\(index + 1)")
            entry.representedObject = mode.rawValue
            device.addItem(entry)
        }
        device.addItem(.separator())
        device.addItem(item("Connect Automatically", #selector(toggleAutoConnect(_:))))
        add(device, titled: "Device", to: main)

        let view = NSMenu()
        view.addItem(item("Show Frame Log", #selector(toggleFrameLog(_:)), "l"))
        add(view, titled: "View", to: main)

        let windowMenu = NSMenu()
        windowMenu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w", target: nil))
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), target: nil))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Sennheiser Control", #selector(showWindow(_:)), "0"))
        add(windowMenu, titled: "Window", to: main)
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func add(_ submenu: NSMenu, titled title: String, to main: NSMenu) {
        submenu.title = title
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        main.addItem(parent)
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        item(title, action, key, modifiers: modifiers, target: self)
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command, target: AnyObject?) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        entry.target = target
        return entry
    }
}

extension NoiseControl.Mode {
    var menuTitle: String {
        switch self {
        case .anc: return "Noise Cancellation"
        case .transparency: return "Transparency"
        case .off: return "Noise Control Off"
        }
    }
}
