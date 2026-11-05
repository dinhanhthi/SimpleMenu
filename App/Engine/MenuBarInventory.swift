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
