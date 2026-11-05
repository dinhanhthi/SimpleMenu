// The app entry: an AppKit delegate that owns the Settings window, its menu and the shared state.
import AppKit
import SwiftUI

/// AppKit entry point: no SwiftUI `App`, so SwiftUI is only loaded inside the window.
@main
@MainActor
enum SimpleMenuApp {
    // NSApplication.delegate is weak; keep the delegate alive for the app lifetime.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

/// Whether the main window shows on screen (not hidden, minimized or covered). Read it with
/// `@Environment(WindowState.self)` to pause timelines and pulses nobody sees.
@Observable
@MainActor
final class WindowState {
    var isVisible = true
}

/// Owns the Settings window, its navigation and the main menu for the app lifetime. No window at launch: the app
/// lives in the menu bar, with a Dock icon only while Settings is open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    /// The selected section; kept across window closes, so a menu can open a section before the window exists.
    let navigation = Navigation()
    let windowState = WindowState()

    /// Accessibility trust, shared by the app; created at launch and never prompts by itself.
    private(set) var accessibility: AccessibilityPermission?
    /// The hiding engine, started at launch and stopped (full bar back) on quit.
    let menuBar = MenuBarController()
    /// Sparkle; stays off until `SUPublicEDKey` is set.
    let updater = Updater()

    #if DEBUG
    /// Keeps the debug command observer alive for the app lifetime.
    private var debugCommands: DebugCommands?
    #endif

    private var window: NSWindow?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceMode.current.apply()
        NSApp.mainMenu = makeMainMenu()
        let accessibility = AccessibilityPermission()
        self.accessibility = accessibility
        menuBar.start(accessibility: accessibility)
        #if DEBUG
        debugCommands = DebugCommands(controller: menuBar)
        #endif
        statusItemController = StatusItemController(menuBar: menuBar, updater: updater,
                                                    onSettings: { [weak self] in self?.showSettings() })
        updater.start()
        Hotkeys.register(menuBar: menuBar)
        // Without Accessibility the app cannot list the menu bar: show why and how to grant it.
        if !accessibility.isTrusted { showSettings(section: .permissions) }
    }

    /// Removes the restriction, so the full menu bar returns when SimpleMenu quits.
    func applicationWillTerminate(_ notification: Notification) {
        menuBar.stop()
    }

    /// Opening the app again (Finder, `open`, Spotlight) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func showMainWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainView(navigation: navigation).environment(windowState)
                .environment(accessibility).environment(menuBar))
            // The window owns its size, not the SwiftUI content.
            hosting.sizingOptions = []
            // The SwiftUI toolbar (the logo) becomes the window's toolbar, in the traffic-light row.
            hosting.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: hosting)
            window.title = "SimpleMenu"
            window.titleVisibility = .hidden
            // Compact: a shorter traffic-light row, so the Settings body starts close under it.
            window.toolbarStyle = .unifiedCompact
            // One background for the toolbar and the content, without a line between them.
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            // Full size content: the background runs under the toolbar too.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 600, height: 420)
            window.setContentSize(NSSize(width: 860, height: 560))
            if !window.setFrameUsingName("MainWindow") { window.center() }
            window.setFrameAutosaveName("MainWindow")
            window.delegate = self
            self.window = window
        }
        bringToFront(window)
    }

    /// Opens Settings on `section`.
    func showSettings(section: SettingsSection) {
        navigation.section = section
        showSettings()
    }

    /// Opens Settings on the last section shown.
    @objc func showSettings() {
        showMainWindow()
    }

    /// Opens Settings on the About section.
    @objc func showAbout() {
        showSettings(section: .about)
    }

    /// Shows the Dock icon and activates the app on the next turn (the `.regular` switch from LSUIElement is
    /// not effective before), then fronts `window`. On macOS 14+ a plain `activate()` is denied on a fresh launch
    /// from LSUIElement; the `ignoringOtherApps:` form is still honored.
    private func bringToFront(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
    }

    /// Drops the Dock icon once Settings is closed, unless another titled window is still open.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // On the next turn, once the window is off screen.
        Task { @MainActor in
            let otherWindowOpen = NSApp.windows.contains {
                $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled)
            }
            if !otherWindowOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windowState.isVisible = window.occlusionState.contains(.visible)
    }

    @objc private func checkForUpdates() { updater.checkForUpdates() }

    /// Disabled while the updater is off (no `SUPublicEDKey` yet).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates) ? updater.canCheckForUpdates : true
    }

    /// App menu (About, Check for Updates, Settings, Hide, Quit), Edit and Window menus: without them text fields lose copy and paste.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SimpleMenu", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings as () -> Void),
                        keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide SimpleMenu", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit SimpleMenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editMenu = NSMenu(title: "Edit")
        // No typed selectors for these: the responder chain (text views, the window's undo manager) answers them.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}
