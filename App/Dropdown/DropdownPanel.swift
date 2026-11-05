// The dropdown: a borderless panel under SimpleMenu's status item that lists the hidden apps and their items, as a
// list or as a bar of icons.
import AppKit
import SwiftUI

/// How the panel shows the hidden items: a vertical list with a Settings button, or one row of app icons.
enum DropdownStyle: String, CaseIterable {
    case dropdown, bar

    var title: String {
        switch self {
        case .dropdown: "Dropdown"
        case .bar: "Bar"
        }
    }
}

/// A non-activating pop-up panel showing `DropdownView`, its top edge pinned under the status item button. Esc, an
/// outside click, losing key, a row and "Settings…" close it. Reused across shows and styles: call
/// `show(below:style:)` and `close()`.
@MainActor
final class DropdownPanel: NSPanel {
    private static let width: CGFloat = 300
    /// Between the button's window and the panel's top edge.
    private static let gap: CGFloat = 4
    /// Kept between the panel and the screen's visible edges.
    private static let margin: CGFloat = 8
    private static let escapeKeyCode: UInt16 = 53

    private let controller: MenuBarController
    private let onSettings: () -> Void
    private var hosting: NSHostingView<DropdownView>?
    private var outsideClickMonitor: Any?
    /// The status button's window frame the panel is pinned under while shown (bottom-left screen coordinates).
    private var anchor: NSRect?
    /// The anchor screen's visible frame: the panel stays inside it, `margin` from its edges.
    private var visibleFrame: NSRect = .zero
    private var style: DropdownStyle = .dropdown
    /// The status button's live window frame: a click there is the toggle's, not an outside click. Read at click
    /// time, since the icon can move while the panel is open.
    private let buttonFrame: () -> NSRect?
    /// The tallest the panel gets on the anchor's screen.
    private var maxHeight: CGFloat = 0

    init(controller: MenuBarController, buttonFrame: @escaping () -> NSRect?, onSettings: @escaping () -> Void) {
        self.controller = controller
        self.buttonFrame = buttonFrame
        self.onSettings = onSettings
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // No `isFloatingPanel`: setting it resets the level to `.floating`.
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        let hosting = NSHostingView(rootView: view(for: style))
        // Intrinsic size only: `fittingSize` measures the content, and the window never resizes itself (its frame
        // is set here, top edge pinned).
        hosting.sizingOptions = [.intrinsicContentSize]
        // Below the window's own size priority, so taller content never grows the window up over the menu bar.
        hosting.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        hosting.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentView = hosting
        self.hosting = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Shows the cached inventory at once under `buttonFrame` (the status item button's window frame, screen
    /// coordinates) in `style`, then starts a background rescan that updates the rows in place.
    func show(below buttonFrame: NSRect, style: DropdownStyle) {
        let screen = NSScreen.screens.first { $0.frame.intersects(buttonFrame) } ?? NSScreen.main
        visibleFrame = screen?.visibleFrame ?? buttonFrame
        anchor = buttonFrame
        self.style = style
        maxHeight = max(top(below: buttonFrame) - visibleFrame.minY - Self.margin, 0)
        hosting?.rootView = view(for: style)
        // Measured after the swap: before it, the size is the previous style's.
        fit(size: hosting?.fittingSize ?? frame.size)
        makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
        controller.rescanInBackground()
    }

    /// Hides the panel and stops watching outside clicks. Every close goes through here.
    override func close() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        anchor = nil
        super.close()
    }

    /// Losing key closes: that catches clicks into SimpleMenu's own windows (Settings), which the global monitor
    /// cannot see. `close()` clears `anchor` before ordering out, so the resign it causes does not re-enter.
    override func resignKey() {
        super.resignKey()
        if anchor != nil { close() }
    }

    /// Esc closes; checked here because `NSHostingView` need not pass `cancelOperation(_:)` up to the window.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == Self.escapeKeyCode {
            close()
            return
        }
        super.sendEvent(event)
    }

    private func view(for style: DropdownStyle) -> DropdownView {
        DropdownView(
            controller: controller,
            style: style,
            onOpen: { [weak self] bundleID, index in self?.openItem(bundleID: bundleID, index: index) },
            onSettings: { [weak self] in self?.openSettings() },
            onSize: { [weak self] size in self?.fit(size: size) })
    }

    /// The panel's top edge: `gap` under the button, never above the visible frame.
    private func top(below buttonFrame: NSRect) -> CGFloat {
        min(buttonFrame.minY, visibleFrame.maxY) - Self.gap
    }

    /// Resizes to `size`, capped to the screen, keeping the top edge under `anchor`. x is recomputed on every fit,
    /// so a bar that a rescan widens still ends at the button: the dropdown's left edge is at the button's left
    /// edge, the bar's right edge at its right edge, both kept on screen.
    private func fit(size: CGSize) {
        guard let anchor, size.width > 0, size.height > 0 else { return }
        let width = min(size.width, max(visibleFrame.width - 2 * Self.margin, 0))
        let height = min(size.height, maxHeight)
        let preferredX = style == .bar ? anchor.maxX - width : anchor.minX
        let x = min(max(preferredX, visibleFrame.minX + Self.margin), visibleFrame.maxX - width - Self.margin)
        let target = NSRect(x: x, y: top(below: anchor) - height, width: width, height: height)
        guard target != frame else { return }
        setFrame(target, display: true)
        invalidateShadow()
    }

    /// A global monitor only sees clicks in other apps; clicks in SimpleMenu's own windows close the panel through
    /// `resignKey()`. It does see clicks on SimpleMenu's own status button (measured on macOS 27): those are left to the button,
    /// which closes the panel on mouse-up, so the same click does not also peek.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let frame = self.buttonFrame(), frame.contains(NSEvent.mouseLocation) { return }
                self.close()
            }
        }
    }

    /// Closes first: `open` waits for a fresh frame and presses, and the panel must not cover the menu.
    private func openItem(bundleID: String, index: Int) {
        close()
        controller.open(bundleID: bundleID, index: index)
    }

    private func openSettings() {
        close()
        onSettings()
    }
}
