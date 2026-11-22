import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = AppState()
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        setupMenuBar()
        state.onStateChanged = { [weak self] in
            self?.rebuildMenu()
        }
        rebuildMenu()
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }

    // MARK: - Window

    @objc private func showMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = ContentView(state: state)
        let hosting = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hosting)
        window.title = "MechPad — Trackpad Mechanical Keyboard"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 700))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "MechPad")
            button.image?.isTemplate = true
        }
        statusItem = item
    }

    private func rebuildMenu() {
        guard let statusItem else { return }

        if let button = statusItem.button {
            let symbol = state.isEnabled ? "keyboard.fill" : "keyboard"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MechPad")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let statusTitle = state.isEnabled
            ? "MechPad: Active (\(state.selectedProfile.name))"
            : "MechPad: Paused"
        let headerItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        let toggleItem = NSMenuItem(
            title: state.isEnabled ? "Pause Keyboard Sound" : "Enable Keyboard Sound",
            action: #selector(toggleEnabled),
            keyEquivalent: "p"
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let profileHeader = NSMenuItem(title: "Switch Profile", action: nil, keyEquivalent: "")
        profileHeader.isEnabled = false
        menu.addItem(profileHeader)

        for profile in SwitchLibrary.all {
            let item = NSMenuItem(
                title: "\(profile.name)  (\(profile.category))",
                action: #selector(selectProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id
            item.state = (profile.id == state.selectedProfileID) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open MechPad Studio…", action: #selector(showMainWindow), keyEquivalent: ",")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: "Quit MechPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        state.isEnabled.toggle()
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        state.selectedProfileID = id
        state.audition(profile: SwitchLibrary.profile(id: id))
    }
}

// Entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
