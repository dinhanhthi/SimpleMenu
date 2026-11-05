import AppKit
import Observation

/// SimpleMenu's own menu bar item, the logo. Left click peeks (or collapses), Option-click opens the dropdown,
/// right-click or Control-click opens SimpleMenu's menu (Settings…, Quit). The logo stays the same; while the bar
/// peeks or an item is open, the button stays highlighted.
@MainActor
final class StatusItemController: NSObject {
    private let menuBar: MenuBarController
    private let onSettings: () -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(menuBar: MenuBarController, onSettings: @escaping () -> Void) {
        self.menuBar = menuBar
        self.onSettings = onSettings
        // Variable length: a square item (about 22 pt) would clip the 25 pt wide logo.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.autosaveName = "SimpleMenu"
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit SimpleMenu", #selector(quit)))
        guard let button = statusItem.button else { return }
        button.image = Self.logo
        button.setAccessibilityLabel("SimpleMenu")
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        observeMode()
        menuBar.configureDropdown(anchor: { [weak self] in self?.statusItem.button?.window?.frame },
                                  onSettings: onSettings)
    }

    /// One-shot tracking of the bar mode, re-registered on every change. `onChange` runs before the new value is
    /// set, so the highlight is read on the next main-actor turn; that also lands after the button's own click
    /// tracking, which would otherwise reset a highlight set inside the action.
    private func observeMode() {
        withObservationTracking {
            _ = menuBar.mode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeMode()
                self?.updateHighlight()
            }
        }
    }

    private func updateHighlight() {
        statusItem.button?.highlight(menuBar.mode != .collapsed)
    }

    /// The logo at 25×16 pt, full colour (not a template): `logo_object_gray` on a light menu bar,
    /// `logo_object_white` on a dark one. Picked at draw time, so it follows the menu bar's appearance live.
    private static let logo = makeLogo()

    /// The PNGs are 1254×1254 at 72 dpi with wide transparent margins: only their opaque box plus 4 px
    /// (bottom-left origin).
    private static let source = NSRect(x: 244, y: 381, width: 766, height: 484)

    /// One logo PNG (`logo_object_gray` or `logo_object_white`) cut to its opaque box, at `height` pt.
    static func logoObject(named name: String, height: CGFloat) -> NSImage? {
        guard let png = NSImage(named: name) else { return nil }
        let size = NSSize(width: (height * source.width / source.height).rounded(), height: height)
        return NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            png.draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    private static func makeLogo() -> NSImage? {
        guard let gray = NSImage(named: "logo_object_gray"), let white = NSImage(named: "logo_object_white") else {
            return nil
        }
        let image = NSImage(size: NSSize(width: 25, height: 16), flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // A large downscale: high interpolation keeps the edges smooth at 1x and 2x.
            NSGraphicsContext.current?.imageInterpolation = .high
            (dark ? white : gray).draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "SimpleMenu"
        return image
    }

    /// Runs on the mouse-up itself and does no work of its own: the button's press highlight is the immediate
    /// reaction, and the menu opens in the same turn. `togglePeek()` flips the mode at once; its rescan follows
    /// asynchronously. Control-click arrives as a left mouse-up with `.control`. The dropdown's outside-click monitor
    /// and the peek monitor see clicks on this button but skip those inside its frame, so with the dropdown open a
    /// click only closes it here (a menu click then opens the menu), and in peek or open a plain click collapses here.
    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // The live state too: on macOS 27 the status item's mouse-up came with no modifier flags while Option was
        // held (measured in a VM).
        let flags = (event?.modifierFlags ?? []).union(NSEvent.modifierFlags)
        let menuClick = event?.type == .rightMouseUp || flags.contains(.control)
        if menuBar.isDropdownVisible {
            menuBar.closeDropdown()
            if !menuClick { return restoreHighlight() }
        }
        if menuClick {
            showMenu(from: sender)
        } else if flags.contains(.option) {
            menuBar.toggleDropdown()
            restoreHighlight()
        } else {
            menuBar.togglePeek()
        }
    }

    /// The dropdown leaves the mode unchanged, so no mode observer puts back the peek or open highlight that the
    /// button's click tracking resets: re-apply it on the next turn, after the tracking.
    private func restoreHighlight() {
        Task { @MainActor in self.updateHighlight() }
    }

    /// Attaches the menu only while it is open: with `statusItem.menu` set, every click would open it and
    /// `clicked` would never run. `performClick` tracks the menu synchronously, so clearing it right after is safe.
    /// The menu's tracking ends un-highlighted, so the peek or open highlight is put back.
    private func showMenu(from button: NSStatusBarButton) {
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
        updateHighlight()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openSettings() { onSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
