import AppKit
import ApplicationServices

/// `AXUIElement` is an immutable CF reference that AX allows from any thread; the box makes that explicit for Swift 6.
struct AXElementBox: @unchecked Sendable {
    let element: AXUIElement
}

/// One third-party status item as AX reports it on the active display.
struct MenuBarItem: Sendable {
    let bundleID: String
    let pid: pid_t
    /// Position among the owning app's `AXExtrasMenuBar` children.
    let index: Int
    /// Global, top-left origin. Stale while the app is restricted (hidden items keep their old frame in AX),
    /// so it is not a visibility signal. `.zero` when AX gives no frame.
    let frame: CGRect
    let title: String?
    /// AXDescription, else AXHelp, else AXIdentifier.
    let detail: String?
    let element: AXElementBox
}

enum MenuBarInventory {
    /// Owners of system items (spike 1.4); they are never in the layout.
    private static let systemOwners: Set<String> = [
        "com.apple.MenuBarAgent", "com.apple.accessoryaccess.uiagent", "com.apple.controlcenter",
    ]

    /// Every third-party status item, sorted by `frame.minX`. Empty unless AX is trusted. Apps that do not answer
    /// within the 0.1 s messaging timeout are skipped. Overflowed items are absent from AX.
    nonisolated static func scan() async -> [MenuBarItem] {
        guard AXIsProcessTrusted() else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanBlocking())
            }
        }
    }

    /// Item `index` of `bundleID` once its frame is in a menu bar strip (`strips`, see `isInMenuBarStrip`) and
    /// equal on two polls 50 ms apart, or nil after 1 s
    /// (the spike's poll limit; every item was pressable within 211 ms). Re-reads the element on every poll.
    /// A hidden item keeps its stale frame, which is on-screen and stable too, so call this only once the layout
    /// delay after the activation that allowed `bundleID` has passed. Apps launched during a restriction have no
    /// items until that activation, which this waits for.
    nonisolated static func waitForFreshFrame(bundleID: String, index: Int, strips: [CGRect]) async -> MenuBarItem? {
        let start = ContinuousClock.now
        var previous: CGRect?
        while !Task.isCancelled, ContinuousClock.now - start <= .seconds(1) {
            let item = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: itemBlocking(bundleID: bundleID, index: index))
                }
            }
            if let item, isInMenuBarStrip(item.frame, strips: strips) {
                if item.frame == previous { return item }
                previous = item.frame
            } else {
                previous = nil
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// The live click gate, read right before a synthetic click: nil when `item` is still on-screen at
    /// `item.frame`, that frame is in a menu bar strip (`strips`, see `isInMenuBarStrip`), and no other item of its app or of `others` (the allowed apps, whose frames are fresh) has a
    /// live frame that holds the click point (`item.frame`'s centre) or overlaps `item.frame` by more than 2 px.
    /// A hidden item keeps a stale frame that another item has moved into, so this tells a laid-out item from a
    /// re-hidden one. Otherwise the reason, naming the item in the way, for the log.
    nonisolated static func notLaidOutReason(_ item: MenuBarItem, others: [(pid: pid_t, bundleID: String)],
                                             strips: [CGRect]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: notLaidOutReasonBlocking(item, others: others, strips: strips))
            }
        }
    }

    /// Posts a real left click at `point` (top-left global, like AX frames) and puts the pointer back. Opens a status
    /// item as the user's own click does. Posting needs Accessibility, as AX does.
    nonisolated static func click(at point: CGPoint) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let saved = CGEvent(source: nil)?.location
                let source = CGEventSource(stateID: .hidSystemState)
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                        mouseButton: .left)
                    event?.setIntegerValueField(.mouseEventClickState, value: 1)
                    event?.post(tap: .cghidEventTap)
                    // Posted events are queued: a warp right away can land first and leave the pointer on the item.
                    usleep(30_000)
                }
                if let saved { CGWarpMouseCursorPosition(saved) }
                CGAssociateMouseAndMouseCursorPosition(1)
                continuation.resume()
            }
        }
    }

    private nonisolated static func notLaidOutReasonBlocking(_ item: MenuBarItem,
                                                             others: [(pid: pid_t, bundleID: String)],
                                                             strips: [CGRect]) -> String? {
        guard AXIsProcessTrusted() else { return "Accessibility not trusted" }
        let found = items(pid: item.pid, bundleID: item.bundleID)
        guard item.index < found.count, isOnScreen(found[item.index].frame) else { return "item gone or off-screen" }
        guard found[item.index].frame == item.frame else { return "item moved" }
        guard isInMenuBarStrip(item.frame, strips: strips) else {
            return "frame \(item.frame) outside the menu bar strip or wider than 400 pt"
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: others.count) { i in
            results.append(items(pid: others[i].pid, bundleID: others[i].bundleID))
        }
        let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
        for other in found.filter({ $0.index != item.index }) + results.all() where other.frame != .zero {
            if other.frame.contains(point) {
                return "click point inside \(other.bundleID) #\(other.index) at \(other.frame)"
            }
            let overlap = item.frame.intersection(other.frame).width
            if overlap > 2 { return "overlaps \(other.bundleID) #\(other.index) by \(overlap) px" }
        }
        return nil
    }

    private nonisolated static func itemBlocking(bundleID: String, index: Int) -> MenuBarItem? {
        guard AXIsProcessTrusted() else { return nil }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let found = items(pid: app.processIdentifier, bundleID: bundleID)
            if index < found.count { return found[index] }
        }
        return nil
    }

    /// Non-empty and on an active display (top-left global, like AX frames).
    private nonisolated static func isOnScreen(_ frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayBounds($0).intersects(frame) }
    }

    private nonisolated static func scanBlocking() -> [MenuBarItem] {
        let skipped = systemOwners.union([Bundle.main.bundleIdentifier].compactMap { $0 })
        let apps: [(pid: pid_t, bundleID: String)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, !skipped.contains(id) else { return nil }
            return (app.processIdentifier, id)
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            results.append(items(pid: apps[i].pid, bundleID: apps[i].bundleID))
        }
        return results.all().sorted { $0.frame.minX < $1.frame.minX }
    }

    private nonisolated static func items(pid: pid_t, bundleID: String) -> [MenuBarItem] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let bar = element(app, "AXExtrasMenuBar"),
              let children = copy(bar, "AXChildren") as? [AXUIElement] else { return [] }
        return children.enumerated().map { index, child in
            MenuBarItem(
                bundleID: bundleID, pid: pid, index: index, frame: frame(child) ?? .zero,
                title: string(child, "AXTitle"),
                detail: string(child, "AXDescription") ?? string(child, "AXHelp") ?? string(child, "AXIdentifier"),
                element: AXElementBox(element: child))
        }
    }

    // MARK: - AX helpers

    private nonisolated static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)  // CFTypeID checked above
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let s = copy(element, attribute) as? String, !s.isEmpty else { return nil }
        return s
    }

    private nonisolated static func value<T: BitwiseCopyable>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType, _ initial: T) -> T? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = initial
        // CFTypeID checked above, so the cast is safe.
        guard AXValueGetValue(value as! AXValue, type, &result) else { return nil }
        return result
    }

    /// AXFrame, or AXPosition + AXSize.
    private nonisolated static func frame(_ element: AXUIElement) -> CGRect? {
        if let rect = value(element, "AXFrame", .cgRect, CGRect.zero) { return rect }
        guard let origin = value(element, "AXPosition", .cgPoint, CGPoint.zero),
              let size = value(element, "AXSize", .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [MenuBarItem] = []

        func append(_ new: [MenuBarItem]) {
            lock.lock()
            items += new
            lock.unlock()
        }

        func all() -> [MenuBarItem] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }
}
