import AppKit

/// SimpleMenu's own menu bar item, the logo. Left click peeks, Option-click opens the dropdown, right-click or
/// Control-click opens SimpleMenu's menu (Settings…, Quit). The click actions are closures set by the app delegate.
@MainActor
final class StatusItemController: NSObject {
    /// Left click. A no-op until Phase 3.
    var onPeek: () -> Void = {}
    /// Option-click. A no-op until Phase 4.
    var onDropdown: () -> Void = {}

    private let onSettings: () -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(onSettings: @escaping () -> Void) {
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
    /// reaction, and the menu opens in the same turn. Control-click arrives as a left mouse-up with `.control`.
    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        if event?.type == .rightMouseUp || flags.contains(.control) {
            showMenu(from: sender)
        } else if flags.contains(.option) {
            onDropdown()
        } else {
            onPeek()
        }
    }

    /// Attaches the menu only while it is open: with `statusItem.menu` set, every click would open it and
    /// `clicked` would never run. `performClick` tracks the menu synchronously, so clearing it right after is safe.
    private func showMenu(from button: NSStatusBarButton) {
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openSettings() { onSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
