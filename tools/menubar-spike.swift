// SimpleMenu Phase 1 spike: menu bar extras via Accessibility, hiding via MenuBarClientCore assessment mode.
//
// Usage (always through tools/run-spike.sh, so Spike.app is its own TCC process):
//   Spike list            --out <log>
//   Spike hide <bundleID> [seconds] [--system-items empty|nil|<n,n,...>] [--expand-unrestricted]
//              [--double | --launch-helpers] [--block-args] --out <log>
//   Spike press <bundleID> [--system-items <n,n,...>] [--open-hold <seconds>] --out <log>
//   Spike helper [--out <log>] [--t0 <epoch>]   (status item owner, launched by `hide --launch-helpers`)
//
// Never links MenuBarClientCore: `hide` and `press` resolve it at runtime (dlopen + NSClassFromString).

import AppKit
import ApplicationServices

// MARK: - Output

/// Writes every line to the --out file (and mirrors it to stdout).
final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    func open(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func line(_ text: String = "") {
        lock.lock()
        defer { lock.unlock() }
        let data = Data((text + "\n").utf8)
        handle?.write(data)
        FileHandle.standardOutput.write(data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}

let log = Log()

/// Last log line is read by run-spike.sh, since `open -W` does not return the app's status.
func finish(_ status: Int32) -> Never {
    log.line("spike-exit-status: \(status)")
    log.close()
    exit(status)
}

// MARK: - Arguments

struct Arguments {
    var command: String?
    var rest: [String] = []
    var outPath: String?

    init(_ argv: [String]) {
        var it = argv.dropFirst().makeIterator()
        while let arg = it.next() {
            if arg == "--out" {
                outPath = it.next()
            } else if arg.hasPrefix("-psn_") {
                continue  // LaunchServices process serial number, if ever passed
            } else if command == nil {
                command = arg
            } else {
                rest.append(arg)
            }
        }
    }
}

// MARK: - AX helpers

func axCopy(_ element: AXUIElement, _ attribute: String) -> (CFTypeRef?, AXError) {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return (value, err)
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    let (value, err) = axCopy(element, attribute)
    guard err == .success, let value else { return nil }
    if let s = value as? String { return s }
    return String(describing: value)
}

func axValue<T: BitwiseCopyable>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType, _ initial: T) -> T? {
    let (value, err) = axCopy(element, attribute)
    guard err == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = initial
    // CFTypeID checked above, so the cast is safe.
    guard AXValueGetValue(value as! AXValue, type, &result) else { return nil }
    return result
}

/// AXFrame, or AXPosition + AXSize. AX coordinates are global, top-left origin.
func axFrame(_ element: AXUIElement) -> (CGRect, String)? {
    if let rect = axValue(element, "AXFrame", .cgRect, CGRect.zero) {
        return (rect, "AXFrame")
    }
    if let pos = axValue(element, "AXPosition", .cgPoint, CGPoint.zero),
       let size = axValue(element, "AXSize", .cgSize, CGSize.zero) {
        return (CGRect(origin: pos, size: size), "AXPosition+AXSize")
    }
    return nil
}

func axErrorName(_ err: AXError) -> String {
    switch err {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete(timeout?)"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown"
    }
}

/// Union of the active displays, in global top-left coordinates (same space as AX).
func activeDisplayBounds() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
}

// MARK: - Inventory

struct AppRef: Sendable {
    let pid: pid_t
    let bundleID: String?
    let name: String?
}

struct ExtraItem: Sendable {
    let bundleID: String?
    let name: String?
    let pid: pid_t
    let index: Int
    let role: String?
    let subrole: String?
    let frame: CGRect?
    let frameSource: String?
    let title: String?
    let description: String?
    let identifier: String?
}

struct AppScan: Sendable {
    let app: AppRef
    let items: [ExtraItem]
    let extrasError: AXError  // error reading AXExtrasMenuBar (.success when present)
}

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var scans: [AppScan] = []

    func append(_ scan: AppScan) {
        lock.lock()
        scans.append(scan)
        lock.unlock()
    }

    func all() -> [AppScan] {
        lock.lock()
        defer { lock.unlock() }
        return scans
    }
}

func scan(_ app: AppRef) -> AppScan {
    let element = AXUIElementCreateApplication(app.pid)
    AXUIElementSetMessagingTimeout(element, 0.1)
    let (extras, err) = axCopy(element, "AXExtrasMenuBar")
    guard err == .success, let extras, CFGetTypeID(extras) == AXUIElementGetTypeID() else {
        return AppScan(app: app, items: [], extrasError: err == .success ? .noValue : err)
    }
    let bar = extras as! AXUIElement  // CFTypeID checked above
    let (children, childErr) = axCopy(bar, "AXChildren")
    guard childErr == .success, let list = children as? [AXUIElement] else {
        return AppScan(app: app, items: [], extrasError: childErr == .success ? .noValue : childErr)
    }
    let items = list.enumerated().map { index, child in
        let frame = axFrame(child)
        return ExtraItem(
            bundleID: app.bundleID, name: app.name, pid: app.pid, index: index,
            role: axString(child, "AXRole"), subrole: axString(child, "AXSubrole"),
            frame: frame?.0, frameSource: frame?.1,
            title: axString(child, "AXTitle"), description: axString(child, "AXDescription"),
            identifier: axString(child, "AXIdentifier"))
    }
    return AppScan(app: app, items: items, extrasError: .success)
}

func fmt(_ v: CGFloat) -> String { String(format: "%.0f", Double(v)) }

func quoted(_ s: String?) -> String {
    guard let s else { return "-" }
    return "\"" + s.replacingOccurrences(of: "\n", with: " ") + "\""
}

func isSystem(_ bundleID: String?) -> Bool {
    bundleID?.hasPrefix("com.apple.") ?? false
}

func runList(apps: [AppRef]) -> Int32 {
    let results = Results()
    let start = DispatchTime.now()
    DispatchQueue.concurrentPerform(iterations: apps.count) { i in
        results.append(scan(apps[i]))
    }
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

    let scans = results.all()
    let displays = activeDisplayBounds()
    func onScreen(_ r: CGRect?) -> Bool {
        guard let r, r.width > 0, r.height > 0 else { return false }
        return displays.contains { $0.intersects(r) }
    }

    let items = scans.flatMap(\.items).sorted { a, b in
        switch (a.frame, b.frame) {
        case let (fa?, fb?): return fa.minX < fb.minX
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return (a.bundleID ?? "") < (b.bundleID ?? "")
        }
    }

    log.line("displays: " + displays.map { "(\(fmt($0.minX)),\(fmt($0.minY)) \(fmt($0.width))x\(fmt($0.height)))" }.joined(separator: " "))
    log.line()
    log.line("menu bar extras, sorted by frame minX (\(items.count) items):")
    for item in items {
        let frame = item.frame.map { "x=\(fmt($0.minX)) y=\(fmt($0.minY)) w=\(fmt($0.width)) h=\(fmt($0.height))" } ?? "frame=-"
        let screen = onScreen(item.frame) ? "on-screen" : "OFF-SCREEN"
        log.line("  \(frame) [\(screen)\(item.frameSource == "AXFrame" ? "" : ", " + (item.frameSource ?? "no frame"))]"
            + "  \(item.bundleID ?? "<no bundle id>") pid=\(item.pid) #\(item.index)"
            + "  role=\(item.role ?? "-") subrole=\(item.subrole ?? "-")"
            + "  title=\(quoted(item.title)) desc=\(quoted(item.description)) id=\(quoted(item.identifier))")
    }

    log.line()
    log.line("owners (bundle ID: items / on-screen, kind):")
    let owners = Dictionary(grouping: scans.filter { !$0.items.isEmpty }, by: { $0.app.bundleID ?? "<no bundle id> pid \($0.app.pid)" })
    var thirdPartyOnScreen = 0
    for key in owners.keys.sorted() {
        let ownerItems = owners[key]!.flatMap(\.items)
        let visible = ownerItems.filter { onScreen($0.frame) }.count
        let system = isSystem(ownerItems.first?.bundleID)
        if !system && visible > 0 { thirdPartyOnScreen += 1 }
        log.line("  \(key): \(ownerItems.count) / \(visible), \(system ? "system" : "third-party")")
    }

    log.line()
    log.line("AXExtrasMenuBar read result per app (count):")
    let byError = Dictionary(grouping: scans, by: { $0.extrasError.rawValue })
    for code in byError.keys.sorted() {
        let group = byError[code]!
        let err = AXError(rawValue: code) ?? .failure
        log.line("  \(code) \(axErrorName(err)): \(group.count)")
        if err != .success && err != .noValue && err != .attributeUnsupported {
            for s in group.sorted(by: { $0.app.pid < $1.app.pid }) {
                log.line("    \(s.app.bundleID ?? s.app.name ?? "?") pid=\(s.app.pid)")
            }
        }
    }

    log.line()
    log.line("apps scanned: \(apps.count), apps with extras: \(owners.count), third-party apps with on-screen items: \(thirdPartyOnScreen)")
    log.line("scan time: \(String(format: "%.1f", elapsedMs)) ms")
    return 0
}

// MARK: - Assessment mode (MenuBarClientCore, private, resolved at runtime)

let menuBarClientCorePath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"

/// Milliseconds since process start, for event and frame-change timestamps.
let processStart = DispatchTime.now()
let processStartEpoch = Date().timeIntervalSince1970  // passed to the helpers as --t0, so their logs share the scale
func stamp() -> String {
    String(format: "[%7.1f ms]", Double(DispatchTime.now().uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000)
}

func isOnScreen(_ r: CGRect?, _ displays: [CGRect]) -> Bool {
    guard let r, r.width > 0, r.height > 0 else { return false }
    return displays.contains { $0.intersects(r) }
}

/// The two private classes plus the selectors the spike calls, every one checked before use.
final class AssessmentMode: @unchecked Sendable {
    let configClass: AnyClass
    let assertionClass: AnyClass

    static let selInitAllowed = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    static let selInitUnrestricted = NSSelectorFromString("initWithUnrestrictedMenuBarItems")
    static let selActivate = NSSelectorFromString("activateWithConfiguration:completionHandler:")
    static let selInvalidate = NSSelectorFromString("invalidate")

    private init(configClass: AnyClass, assertionClass: AnyClass) {
        self.configClass = configClass
        self.assertionClass = assertionClass
    }

    /// dlopen + NSClassFromString, and log the type encodings. Nil (with the reason logged) if anything is missing.
    static func resolve() -> AssessmentMode? {
        guard dlopen(menuBarClientCorePath, RTLD_NOW) != nil else {
            log.line("API-UNUSABLE: dlopen failed: \(dlerror().map { String(cString: $0) } ?? "?")")
            return nil
        }
        log.line("dlopen MenuBarClientCore: ok")
        guard let config: AnyClass = NSClassFromString("MBAssessmentModeConfiguration") else {
            log.line("API-UNUSABLE: class MBAssessmentModeConfiguration missing")
            return nil
        }
        guard let assertion: AnyClass = NSClassFromString("MBAssessmentModeAssertion") else {
            log.line("API-UNUSABLE: class MBAssessmentModeAssertion missing")
            return nil
        }
        let checks: [(AnyClass, String, Bool)] = [
            (config, "initWithAllowedSystemItems:allowedBundleIdentifiers:", true),
            (config, "initWithUnrestrictedMenuBarItems", true),
            (assertion, "activateWithConfiguration:completionHandler:", true),
            (assertion, "invalidate", true),
            (assertion, "activate:completion:", false),
            (assertion, "activateWithCompletionHandler:", false),
        ]
        var ok = true
        log.line("type encodings:")
        for check in checks {
            let (cls, name, required): (AnyClass, String, Bool) = check
            let sel = NSSelectorFromString(name)
            if class_respondsToSelector(cls, sel), let method = class_getInstanceMethod(cls, sel),
               let encoding = method_getTypeEncoding(method) {
                log.line("  -[\(NSStringFromClass(cls)) \(name)] \(String(cString: encoding))")
            } else {
                log.line("  -[\(NSStringFromClass(cls)) \(name)] MISSING\(required ? " (required)" : "")")
                if required { ok = false }
            }
        }
        if !ok {
            log.line("API-UNUSABLE: a required selector is missing")
            return nil
        }
        return AssessmentMode(configClass: config, assertionClass: assertion)
    }

    /// [[MBAssessmentModeConfiguration alloc] initWithAllowedSystemItems:allowedBundleIdentifiers:]
    func makeConfig(systemItems: NSArray?, bundleIDs: NSArray) -> NSObject? {
        guard let allocated = alloc(configClass) else { return nil }
        typealias InitFn = @convention(c) (AnyObject, Selector, NSArray?, NSArray?) -> Unmanaged<AnyObject>?
        guard allocated.responds(to: Self.selInitAllowed), let imp = allocated.method(for: Self.selInitAllowed) else {
            log.line("config does not respond to initWithAllowedSystemItems:allowedBundleIdentifiers:")
            return nil
        }
        // init consumes the +1 from alloc and returns a +1 result: take it exactly once.
        return unsafeBitCast(imp, to: InitFn.self)(allocated, Self.selInitAllowed, systemItems, bundleIDs)?
            .takeRetainedValue() as? NSObject
    }

    /// [[MBAssessmentModeConfiguration alloc] initWithUnrestrictedMenuBarItems]
    func makeUnrestrictedConfig() -> NSObject? {
        guard let allocated = alloc(configClass) else { return nil }
        typealias InitFn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        guard allocated.responds(to: Self.selInitUnrestricted), let imp = allocated.method(for: Self.selInitUnrestricted) else {
            log.line("config does not respond to initWithUnrestrictedMenuBarItems")
            return nil
        }
        return unsafeBitCast(imp, to: InitFn.self)(allocated, Self.selInitUnrestricted)?.takeRetainedValue() as? NSObject
    }

    private func alloc(_ cls: AnyClass) -> NSObject? {
        let selAlloc = NSSelectorFromString("alloc")
        guard let meta = object_getClass(cls), class_respondsToSelector(meta, selAlloc),
              let imp = class_getMethodImplementation(meta, selAlloc) else { return nil }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        // The +1 from alloc is handed to init (which consumes it), so read it unretained here.
        return unsafeBitCast(imp, to: AllocFn.self)(cls, selAlloc)?.takeUnretainedValue() as? NSObject
    }

    /// New assertion, then -activateWithConfiguration:completionHandler:. `blockArgs` selects the contingency
    /// completion form that logs two raw pointer-sized arguments (BOOL or object) instead of none.
    func activate(_ config: NSObject, label: String, blockArgs: Bool) -> NSObject? {
        guard let type = assertionClass as? NSObject.Type else { return nil }
        let assertion = type.init()
        guard assertion.responds(to: Self.selActivate), let imp = assertion.method(for: Self.selActivate) else {
            log.line("\(label): assertion does not respond to activateWithConfiguration:completionHandler:")
            return nil
        }
        let called = Flag()
        log.line("\(stamp()) \(label): activateWithConfiguration:completionHandler: (block \(blockArgs ? "(ptr, ptr)" : "()"))")
        if blockArgs {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void) -> Void
            let completion: @convention(block) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void = { a, b in
                called.set()
                log.line("\(stamp()) \(label): completion(a=\(a.map { "\($0)" } ?? "0x0"), b=\(b.map { "\($0)" } ?? "0x0")) main=\(Thread.isMainThread)")
            }
            unsafeBitCast(imp, to: Fn.self)(assertion, Self.selActivate, config, completion)
        } else {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) () -> Void) -> Void
            let completion: @convention(block) () -> Void = {
                called.set()
                log.line("\(stamp()) \(label): completion() main=\(Thread.isMainThread)")
            }
            unsafeBitCast(imp, to: Fn.self)(assertion, Self.selActivate, config, completion)
        }
        log.line("\(stamp()) \(label): activate returned")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if !called.isSet { log.line("\(stamp()) \(label): completion not called within 3 s") }
        }
        return assertion
    }

    func invalidate(_ assertion: NSObject, label: String) {
        guard assertion.responds(to: Self.selInvalidate), let imp = assertion.method(for: Self.selInvalidate) else {
            log.line("\(label): assertion does not respond to invalidate")
            return
        }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(imp, to: Fn.self)(assertion, Self.selInvalidate)
        log.line("\(stamp()) \(label): invalidate returned")
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Polls the AX extras of a few pids every 20 ms off the main thread and logs every change with a timestamp.
final class FrameMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var tracked: [(label: String, app: AppRef)] = []
    private var last: [pid_t: String] = [:]
    private var running = false
    private let displays = activeDisplayBounds()

    func track(_ label: String, _ app: AppRef) {
        lock.lock()
        tracked.append((label, app))
        lock.unlock()
    }

    func signature(_ app: AppRef) -> String {
        let s = scan(app)
        if s.items.isEmpty { return "no items (\(axErrorName(s.extrasError)))" }
        return s.items.map { item in
            let frame = item.frame.map { "x=\(fmt($0.minX)) y=\(fmt($0.minY)) w=\(fmt($0.width)) h=\(fmt($0.height))" } ?? "frame=-"
            return "#\(item.index) \(frame) \(isOnScreen(item.frame, displays) ? "on-screen" : "OFF-SCREEN")"
        }.joined(separator: "; ")
    }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                lock.lock()
                let keepGoing = running
                let current = tracked
                lock.unlock()
                if !keepGoing { break }
                for (label, app) in current {
                    let sig = signature(app)
                    lock.lock()
                    let changed = last[app.pid] != sig
                    last[app.pid] = sig
                    lock.unlock()
                    if changed { log.line("\(stamp()) frame \(label) pid=\(app.pid): \(sig)") }
                }
                usleep(20_000)
            }
        }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// Fresh scan of every tracked pid, logged under a checkpoint name.
    func checkpoint(_ name: String) {
        lock.lock()
        let current = tracked
        lock.unlock()
        log.line("\(stamp()) checkpoint \(name):")
        for (label, app) in current {
            log.line("    \(label) pid=\(app.pid): \(signature(app))")
            if app.bundleID == "com.apple.MenuBarAgent" { describeSystemItems(app) }
        }
    }

    /// System items carry no title at the top level: log the labels found in each item's subtree.
    func describeSystemItems(_ app: AppRef) {
        let element = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard case let (extras?, .success) = axCopy(element, "AXExtrasMenuBar"), CFGetTypeID(extras) == AXUIElementGetTypeID(),
              let items = axCopy(extras as! AXUIElement, "AXChildren").0 as? [AXUIElement] else { return }  // CFTypeID checked
        func labels(_ el: AXUIElement, depth: Int) -> [String] {
            var out = ["AXDescription", "AXTitle", "AXValue", "AXIdentifier", "AXHelp"].compactMap { attr -> String? in
                guard let v = axString(el, attr), !v.isEmpty else { return nil }
                return "\(attr.dropFirst(2))=\(quoted(v))"
            }
            if depth < 3, let children = axCopy(el, "AXChildren").0 as? [AXUIElement] {
                for child in children { out += labels(child, depth: depth + 1) }
            }
            return out
        }
        for (i, item) in items.enumerated() {
            let frame = axFrame(item).map { "x=\(fmt($0.0.minX)) w=\(fmt($0.0.width))" } ?? "frame=-"
            log.line("    system item #\(i) \(frame): \(labels(item, depth: 0).joined(separator: " "))")
        }
    }
}

struct HideOptions {
    var target = ""
    var seconds = 10.0
    // Default keeps clock (2), Wi-Fi (6) and Control Center (8); empty and nil hide every system item.
    var systemItems: NSArray? = [2, 6, 8].map { NSNumber(value: $0) } as NSArray
    var systemItemsName = "[2,6,8]"
    var expandUnrestricted = false
    var double = false
    var launchHelpers = false
    var blockArgs = false

    /// hide <bundleID> [seconds] [--system-items empty|nil|<id,id,...>] [--expand-unrestricted]
    ///      [--double | --launch-helpers] [--block-args]
    init?(_ rest: [String]) {
        var positional: [String] = []
        var it = rest.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--system-items":
                switch it.next() {
                case "empty": systemItems = NSArray(); systemItemsName = "empty"
                case "nil": systemItems = nil; systemItemsName = "nil"
                case let list?:  // comma-separated, e.g. 2,6,8 (numbers go in as NSNumber, the type the config stores)
                    let ids = list.split(separator: ",").map(String.init)
                    systemItems = ids.map { Int($0).map { NSNumber(value: $0) } ?? $0 as NSString } as NSArray
                    systemItemsName = "[" + ids.joined(separator: ",") + "]"
                case nil: return nil
                }
            case "--expand-unrestricted": expandUnrestricted = true
            case "--double": double = true
            case "--launch-helpers": launchHelpers = true
            case "--block-args": blockArgs = true
            default:
                if arg.hasPrefix("--") { return nil }
                positional.append(arg)
            }
        }
        guard let first = positional.first, positional.count <= 2 else { return nil }
        target = first
        if positional.count == 2 {
            guard let s = Double(positional[1]), s > 0 else { return nil }
            seconds = s
        }
        if double && launchHelpers { return nil }  // both re-apply mid-run: keep the timelines apart
        if launchHelpers {
            guard target == helperBundleID else { return nil }  // the launched helper app is the target
            seconds = max(seconds, 14)
        }
    }
}

/// The whole `hide` run, driven by main-queue timers. All methods run on the main thread.
final class HideRun: @unchecked Sendable {
    let mode: AssessmentMode
    let options: HideOptions
    let monitor = FrameMonitor()
    var current: NSObject?
    var currentLabel = ""
    var launched: [(name: String, app: NSRunningApplication)] = []
    var helperBare: Process?
    var probePid: pid_t?
    var thirdParty: [AppRef] = []  // baseline third-party owners: allowed in every stage, so their frames are real
    var agent: AppRef?

    init(mode: AssessmentMode, options: HideOptions) {
        self.mode = mode
        self.options = options
    }

    /// Every running bundle ID except the target. With --launch-helpers, staged:
    /// 0 = also without Spike itself (the bare helper's responsible app), 1 = without the target only, 2 = everything.
    var launchStage = 1
    func allowList() -> [String] {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        switch (options.launchHelpers, launchStage) {
        case (true, 0): return ids.subtracting([options.target, Bundle.main.bundleIdentifier ?? "-"]).sorted()
        case (true, 2): return ids.sorted()
        default: return ids.subtracting([options.target]).sorted()
        }
    }

    func apply(_ label: String) -> NSObject? {
        let ids = allowList()
        log.line("\(stamp()) \(label): allow-list \(ids.count) bundle IDs (self included: \(ids.contains(Bundle.main.bundleIdentifier ?? "-")),"
            + " target included: \(ids.contains(options.target))), allowedSystemItems=\(options.systemItemsName)")
        guard let config = mode.makeConfig(systemItems: options.systemItems, bundleIDs: ids as NSArray) else {
            log.line("\(label): could not build the configuration")
            return nil
        }
        let sys = config.value(forKey: "allowedSystemItems").map { "\($0)" } ?? "nil"
        let bundles = (config.value(forKey: "allowedBundleIdentifiers") as? NSArray)?.count ?? -1
        log.line("\(stamp()) \(label): config \(type(of: config)) allowedSystemItems=\(sys.replacingOccurrences(of: "\n", with: " ")) allowedBundleIdentifiers.count=\(bundles)")
        return mode.activate(config, label: label, blockArgs: options.blockArgs)
    }

    /// Activate the replacement first, then invalidate the old one (the product's re-apply order).
    func reapply(_ label: String) {
        let old = current
        let oldLabel = currentLabel
        guard let next = apply(label) else { finishRun(2); return }
        current = next
        currentLabel = label
        if let old { mode.invalidate(old, label: oldLabel) }
    }

    func start(baseline: [AppScan]) {
        let targetScan = baseline.first { $0.app.bundleID == options.target && !$0.items.isEmpty }
        if !options.launchHelpers && !(targetScan?.items.contains { $0.frame != nil } ?? false) {
            log.line("target \(options.target) has no menu bar items with a frame (is it running?)")
            finishRun(2)
            return
        }
        // Track every owner: a hidden item may keep a stale frame, so the shift of the others is the real signal.
        for owner in baseline.filter({ !$0.items.isEmpty }).sorted(by: { ($0.items.first?.frame?.minX ?? 0) < ($1.items.first?.frame?.minX ?? 0) }) {
            let id = owner.app.bundleID ?? "<no bundle id>"
            let kind = owner.app.pid == targetScan?.app.pid ? "TARGET " : (isSystem(id) ? "system " : "")
            monitor.track(kind + id, owner.app)
            if isSystem(id) {
                if id == "com.apple.MenuBarAgent" { agent = owner.app }
            } else if owner.app.pid != targetScan?.app.pid {
                thirdParty.append(owner.app)
            }
        }
        monitor.checkpoint("baseline")
        monitor.start()

        launchStage = options.launchHelpers ? 0 : 1
        guard let first = apply("A1") else { finishRun(2); return }
        current = first
        currentLabel = "A1"
        let n = options.seconds

        after(1.5) { $0.monitor.checkpoint("restricted A1 +1.5s") }
        if options.double {
            after(n / 2) { run in
                run.monitor.checkpoint("before double")
                run.reapply("A2-double")
            }
            after(n / 2 + 1) { $0.monitor.checkpoint("after double +1s") }
        }
        if options.launchHelpers {
            // Subjects: the helper app (the target, never allowed until A3) and the bare helper (no bundle ID, 100 px).
            // The probe app is always allowed and launched last, so it sits left of both: the gap between it and
            // the leftmost baseline third-party item says which subjects are visible.
            after(2) { $0.launchSubjects() }
            after(3) { $0.launchApp("probe", "SpikeProbe.app") }
            after(5) { $0.check("A1, all three launched under it (before any re-apply)") }
            after(5.5) { $0.reapply("A1-reapplied") }
            after(7.5) { $0.check("A1 re-applied: same list (no Spike, no helper)") }
            after(8) { run in run.launchStage = 1; run.reapply("A2") }
            after(10) { $0.check("A2: + Spike (bare helper's responsible app), still no helper") }
            after(10.5) { run in run.launchStage = 2; run.reapply("A3") }
            after(12.5) { $0.check("A3: + helper app (everything allowed)") }
        }
        after(n) { run in
            run.monitor.checkpoint("before restore")
            if run.options.expandUnrestricted {
                run.expandThenInvalidate()
            } else {
                if let c = run.current { run.mode.invalidate(c, label: run.currentLabel) }
                run.current = nil
                run.after(1.5) { run in
                    run.check("after invalidate +1.5s")
                    run.finishRun(0)
                }
            }
        }
    }

    /// Checkpoint plus, with --launch-helpers, the probe gap: about 5 px = no subject visible,
    /// + ~70 = helper app visible, + ~105 = bare helper visible (100 px item). Void when the bar overflows.
    func check(_ name: String) {
        monitor.checkpoint(name)
        guard options.launchHelpers else { return }
        let overflow = agent.map { scan($0).items.contains { $0.identifier == "menu-bar-overflow-indicator" } } ?? false
        let leftmost = thirdParty.compactMap { scan($0).items.compactMap(\.frame).map(\.minX).min() }.min()
        let probe = probePid.flatMap { pid in scan(AppRef(pid: pid, bundleID: nil, name: nil)).items.first?.frame }
        let gap = leftmost.flatMap { l in probe.map { "\(fmt(l - $0.maxX)) px" } } ?? "-"
        log.line("    PROBE GAP at \(name): probe=\(probe.map { "x=\(fmt($0.minX)) w=\(fmt($0.width))" } ?? "no item")"
            + " leftmost third-party minX=\(leftmost.map { fmt($0) } ?? "-") gap=\(gap) overflow=\(overflow)\(overflow ? " (INCONCLUSIVE)" : "")")
    }

    func expandThenInvalidate() {
        guard let config = mode.makeUnrestrictedConfig() else { finishRun(2); return }
        let sys = config.value(forKey: "allowedSystemItems").map { "\($0)" } ?? "nil"
        let bundles = config.value(forKey: "allowedBundleIdentifiers").map { "\($0)" } ?? "nil"
        log.line("\(stamp()) U: unrestricted config allowedSystemItems=\(sys.replacingOccurrences(of: "\n", with: " ")) allowedBundleIdentifiers=\(bundles.replacingOccurrences(of: "\n", with: " "))")
        guard let unrestricted = mode.activate(config, label: "U-expand", blockArgs: options.blockArgs) else { finishRun(2); return }
        if let c = current { mode.invalidate(c, label: currentLabel) }
        current = unrestricted
        currentLabel = "U-expand"
        after(1.5) { run in
            run.monitor.checkpoint("after expand (U active, restriction invalidated) +1.5s")
            if let c = run.current { run.mode.invalidate(c, label: run.currentLabel) }
            run.current = nil
            run.after(1.5) { run in
                run.monitor.checkpoint("after invalidating U +1.5s")
                run.finishRun(0)
            }
        }
    }

    /// A helper bundle next to Spike.app, run as `helper` (it logs its own status item window).
    func launchApp(_ name: String, _ bundle: String) {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(bundle)
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["helper", "--out", logPath(name), "--t0", "\(processStartEpoch)"]
        config.createsNewApplicationInstance = true
        config.activates = false
        log.line("\(stamp()) launching \(name) \(url.path)")
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            DispatchQueue.main.async {
                guard let app else {
                    log.line("\(stamp()) \(name) launch failed: \(error.map { "\($0)" } ?? "?")")
                    return
                }
                self.launched.append((name, app))
                if name == "probe" { self.probePid = app.processIdentifier }
                log.line("\(stamp()) \(name) pid=\(app.processIdentifier) bundleID=\(app.bundleIdentifier ?? "nil")")
                self.monitor.track("\(name) \(app.bundleIdentifier ?? "nil")", AppRef(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName))
            }
        }
    }

    func launchSubjects() {
        launchApp("helper", "SpikeHelper.app")
        let bare = Process()
        bare.executableURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("SpikeHelperBare")
        bare.arguments = ["helper", "--out", logPath("bare"), "--t0", "\(processStartEpoch)"]
        do {
            try bare.run()
            helperBare = bare
            let pid = bare.processIdentifier
            log.line("\(stamp()) bare helper pid=\(pid)")
            monitor.track("bare helper (unbundled)", AppRef(pid: pid, bundleID: nil, name: "SpikeHelperBare"))
            after(1.5) { _ in
                let running = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
                log.line("\(stamp()) bare helper in runningApplications: \(running != nil), bundleIdentifier=\(running?.bundleIdentifier ?? "nil")")
            }
        } catch {
            log.line("\(stamp()) bare helper launch failed: \(error)")
        }
    }

    func after(_ seconds: Double, _ body: @escaping @Sendable (HideRun) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { body(self) }
    }

    func finishRun(_ status: Int32) {
        if let c = current { mode.invalidate(c, label: currentLabel) }
        current = nil
        monitor.stop()
        for (name, app) in launched {
            kill(app.processIdentifier, SIGTERM)
            log.line("\(name) terminated")
        }
        if let bare = helperBare, bare.isRunning {
            bare.terminate()
            log.line("bare helper terminated")
        }
        // The helpers log their own status item window (same ms scale via --t0): fold those logs in here.
        for name in ["helper", "bare", "probe"] {
            guard let text = try? String(contentsOfFile: logPath(name), encoding: .utf8) else { continue }
            log.line("\(name) own log:")
            for line in text.split(separator: "\n") { log.line("    \(line)") }
            try? FileManager.default.removeItem(atPath: logPath(name))
        }
        finish(status)
    }

    private func logPath(_ kind: String) -> String {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("spike-helper-\(kind)-\(getpid()).log").path
    }
}

let helperBundleID = "com.math2it.simplemenu.spike.helper"

/// `hide`: baseline scan off the main thread, then the timeline on the main thread.
func startHide(_ rest: [String], apps: [AppRef]) {
    guard let options = HideOptions(rest) else {
        log.line("usage: Spike hide <bundleID> [seconds] [--system-items empty|nil|<id,id,...>] [--expand-unrestricted] [--double | --launch-helpers] [--block-args]")
        finish(64)
    }
    guard let mode = AssessmentMode.resolve() else { finish(4) }
    log.line("hide \(options.target) for \(options.seconds) s, allowedSystemItems=\(options.systemItemsName), expandUnrestricted=\(options.expandUnrestricted),"
        + " double=\(options.double), launchHelpers=\(options.launchHelpers), blockArgs=\(options.blockArgs)")
    let results = Results()
    DispatchQueue.concurrentPerform(iterations: apps.count) { i in
        results.append(scan(apps[i]))
    }
    let baseline = results.all()
    let run = HideRun(mode: mode, options: options)
    DispatchQueue.main.async { run.start(baseline: baseline) }
}

// MARK: - Press (re-allow a hidden item, AXPress it, re-restrict while open)

struct PressOptions {
    var target = ""
    // Default allows every system item, so the system items never move and the neighbour signal stays clean.
    var systemItems: NSArray? = (0...8).map { NSNumber(value: $0) } as NSArray
    var systemItemsName = "[0..8]"
    var openHold = 1.0  // seconds the menu stays open before the re-restrict

    /// press <bundleID> [--system-items <id,id,...>] [--open-hold <seconds>]
    init?(_ rest: [String]) {
        var positional: [String] = []
        var it = rest.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--system-items":
                guard let list = it.next() else { return nil }
                let ids = list.split(separator: ",").compactMap { Int($0) }
                guard !ids.isEmpty else { return nil }
                systemItems = ids.map { NSNumber(value: $0) } as NSArray
                systemItemsName = "[" + ids.map(String.init).joined(separator: ",") + "]"
            case "--open-hold":
                guard let s = it.next().flatMap(Double.init), s > 0 else { return nil }
                openHold = s
            default:
                if arg.hasPrefix("--") { return nil }
                positional.append(arg)
            }
        }
        guard positional.count == 1 else { return nil }
        target = positional[0]
    }

    var allSystemItems: Bool { systemItemsName == "[0..8]" }
}

/// One window of a process, from CGWindowListCopyWindowInfo (bounds, layer and owner need no Screen Recording).
struct CGWin: Equatable {
    let number: Int
    let layer: Int
    let bounds: CGRect
    let onscreen: Bool

    var text: String { "#\(number) L\(layer) x=\(fmt(bounds.minX)) y=\(fmt(bounds.minY)) \(fmt(bounds.width))x\(fmt(bounds.height))\(onscreen ? "" : " offscreen")" }
}

func cgWindows(_ pid: pid_t) -> [CGWin] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { d in
        guard (d[kCGWindowOwnerPID as String] as? Int) == Int(pid),
              let number = d[kCGWindowNumber as String] as? Int,
              let boundsDict = d[kCGWindowBounds as String] as! CFDictionary?,  // always a CFDictionary when present
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        return CGWin(number: number, layer: d[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
                     onscreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }
}

func extrasElements(_ pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.1)
    guard case let (extras?, .success) = axCopy(app, "AXExtrasMenuBar"), CFGetTypeID(extras) == AXUIElementGetTypeID(),
          let items = axCopy(extras as! AXUIElement, "AXChildren").0 as? [AXUIElement] else { return [] }  // CFTypeID checked
    return items
}

func axChildren(_ el: AXUIElement) -> ([AXUIElement], AXError) {
    let (value, err) = axCopy(el, "AXChildren")
    return ((value as? [AXUIElement]) ?? [], err)
}

func msSince(_ t: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
}

struct UncheckedBox<T>: @unchecked Sendable { let value: T }

/// The whole `press` run, on one background thread; assertions are activated and invalidated on the main thread.
final class PressRun: @unchecked Sendable {
    let mode: AssessmentMode
    let options: PressOptions
    let monitor = FrameMonitor()  // checkpoints only (no continuous polling: it would compete with the 50 ms poll)
    let displays = activeDisplayBounds()
    var target = AppRef(pid: 0, bundleID: nil, name: nil)
    var targetIndex = 0
    var baselineFrame = CGRect.zero
    var neighbour: (app: AppRef, index: Int, label: String, baselineX: CGFloat)?
    var hiddenConfirmed = false
    private var lastNote: [String: String] = [:]
    // Main thread only.
    var current: NSObject?
    var currentLabel = ""

    init(mode: AssessmentMode, options: PressOptions) {
        self.mode = mode
        self.options = options
    }

    func onMain(_ body: () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.sync(execute: body) }
    }

    /// New assertion first, then invalidate the previous one.
    func apply(_ label: String, allowTarget: Bool) -> Bool {
        var ok = false
        onMain {
            var ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            if allowTarget { ids.insert(options.target) } else { ids.remove(options.target) }
            let list = ids.sorted()
            log.line("\(stamp()) \(label): allow-list \(list.count) bundle IDs (target included: \(allowTarget)), allowedSystemItems=\(options.systemItemsName)")
            guard let config = mode.makeConfig(systemItems: options.systemItems, bundleIDs: list as NSArray),
                  let next = mode.activate(config, label: label, blockArgs: false) else {
                log.line("\(label): could not build or activate the configuration")
                return
            }
            let old = current
            let oldLabel = currentLabel
            current = next
            currentLabel = label
            if let old { mode.invalidate(old, label: oldLabel) }
            ok = true
        }
        return ok
    }

    func invalidateAll() {
        onMain {
            if let c = current { mode.invalidate(c, label: currentLabel) }
            current = nil
        }
    }

    func end(_ status: Int32) -> Never {
        invalidateAll()
        finish(status)
    }

    /// Logs `value` under `key` only when it changed since the last call.
    func note(_ key: String, _ value: String, _ t0: DispatchTime) {
        guard lastNote[key] != value else { return }
        lastNote[key] = value
        log.line("\(stamp()) +\(String(format: "%5.0f", msSince(t0))) ms \(key): \(value)")
    }

    func targetItem() -> AXUIElement? {
        let items = extrasElements(target.pid)
        return targetIndex < items.count ? items[targetIndex] : nil
    }

    func neighbourX() -> CGFloat? {
        guard let n = neighbour else { return nil }
        let items = extrasElements(n.app.pid)
        return n.index < items.count ? axFrame(items[n.index])?.0.minX : nil
    }

    func frameText(_ r: CGRect?) -> String {
        guard let r else { return "frame=-" }
        return "x=\(fmt(r.minX)) y=\(fmt(r.minY)) w=\(fmt(r.width)) h=\(fmt(r.height)) \(isOnScreen(r, displays) ? "on-screen" : "OFF-SCREEN")"
    }

    /// The target's status item window(s): CG layer 25 (kCGStatusWindowLevel).
    func statusWindows() -> String {
        let wins = cgWindows(target.pid).filter { $0.layer == 25 }
        return wins.isEmpty ? "none" : wins.map(\.text).joined(separator: "; ")
    }

    /// AX view of the item while (possibly) open: its children's roles, AXSelected, and the app's AXWindows.
    func axOpenState(_ item: AXUIElement?) -> (text: String, hasMenu: Bool, windows: Int) {
        var parts: [String] = []
        var hasMenu = false
        if let item {
            let (children, err) = axChildren(item)
            let roles = children.map { axString($0, "AXRole") ?? "?" }
            hasMenu = roles.contains("AXMenu")
            parts.append("item children=\(err == .success ? "[\(roles.joined(separator: ","))]" : axErrorName(err))")
            parts.append("AXSelected=\(axString(item, "AXSelected") ?? "-")")
        } else {
            parts.append("item=missing")
        }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let (wv, werr) = axCopy(app, "AXWindows")
        let wins = (wv as? [AXUIElement]) ?? []
        let desc = wins.map { w in "\(axString(w, "AXRole") ?? "?")/\(axString(w, "AXSubrole") ?? "-") \(axFrame(w).map { frameText($0.0) } ?? "frame=-")" }
        parts.append("AXWindows=\(werr == .success ? "\(wins.count) [\(desc.joined(separator: "; "))]" : axErrorName(werr))")
        return (parts.joined(separator: " "), hasMenu, wins.count)
    }

    func newWindows(since pre: Set<Int>) -> [CGWin] {
        cgWindows(target.pid).filter { $0.onscreen && !pre.contains($0.number) }
    }

    /// Reaches below the bar from around its bottom edge (menu windows can start above it, e.g. y=-35 on 27.2)
    /// and overlaps the item horizontally: the menu or popover.
    func nearItem(_ w: CGWin, _ item: CGRect) -> Bool {
        w.bounds.minY <= item.maxY + 40 && w.bounds.maxY > item.maxY
            && w.bounds.maxX >= item.minX && w.bounds.minX <= item.maxX
    }

    func press(_ item: AXUIElement, label: String) -> Flag {
        let done = Flag()
        let box = UncheckedBox(value: item)
        Thread.detachNewThread {
            AXUIElementSetMessagingTimeout(box.value, 1.0)  // per element: does not inherit the app's 0.1 s
            let t = DispatchTime.now()
            log.line("\(stamp()) \(label): AXUIElementPerformAction(AXPress) ...")
            let err = AXUIElementPerformAction(box.value, kAXPressAction as CFString)
            log.line("\(stamp()) \(label): AXPress returned \(err.rawValue) \(axErrorName(err)) after \(String(format: "%.0f", msSince(t))) ms")
            done.set()
        }
        return done
    }

    func run(baseline: [AppScan]) {
        // Never outlive a stuck AX call: process exit restores the bar too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            log.line("\(stamp()) DEADLINE (30 s): invalidating and exiting")
            self.end(5)
        }
        log.line("displays: " + displays.map { "(\(fmt($0.minX)),\(fmt($0.minY)) \(fmt($0.width))x\(fmt($0.height)))" }.joined(separator: " "))
        guard let ts = baseline.first(where: { $0.app.bundleID == options.target && $0.items.contains { isOnScreen($0.frame, displays) } }),
              let item = ts.items.first(where: { isOnScreen($0.frame, displays) }), let frame = item.frame else {
            log.line("target \(options.target) has no on-screen menu bar item in AX (not running, or overflowed / on the other display's bar?)")
            end(2)
        }
        target = ts.app
        targetIndex = item.index
        baselineFrame = frame
        log.line("target \(options.target) pid=\(target.pid) #\(targetIndex) \(frameText(frame)) title=\(quoted(item.title))")

        // Nearest allowed item to the left on the same bar (system items only when they all stay allowed).
        let candidates = baseline.filter { $0.app.pid != target.pid && (options.allSystemItems || !isSystem($0.app.bundleID)) }
            .flatMap(\.items)
            .filter { $0.identifier != "menu-bar-overflow-indicator" && isOnScreen($0.frame, displays) }
            .filter { $0.frame!.maxX <= frame.minX + 1 && abs($0.frame!.midY - frame.midY) < 20 }  // isOnScreen implies a frame
        if let n = candidates.max(by: { $0.frame!.maxX < $1.frame!.maxX }) {
            let app = baseline.first { $0.app.pid == n.pid }!.app
            neighbour = (app, n.index, "\(n.bundleID ?? "?") #\(n.index)", n.frame!.minX)
            log.line("left neighbour: \(n.bundleID ?? "?") pid=\(n.pid) #\(n.index) baseline x=\(fmt(n.frame!.minX)) w=\(fmt(n.frame!.width))")
        } else {
            log.line("left neighbour: none (target is leftmost): the pressable gate uses the target frame only")
        }

        if let el = targetItem() {
            var names: CFArray?
            let err = AXUIElementCopyActionNames(el, &names)
            log.line("target item actions: \(err == .success ? "\((names as? [String]) ?? [])" : axErrorName(err))")
        }
        let baseWins = cgWindows(target.pid)
        log.line("target CG windows at baseline (\(baseWins.count)): " + baseWins.map(\.text).joined(separator: "; "))
        for owner in baseline.filter({ !$0.items.isEmpty }) {
            let id = owner.app.bundleID ?? "<no bundle id>"
            monitor.track((owner.app.pid == target.pid ? "TARGET " : (isSystem(id) ? "system " : "")) + id, owner.app)
        }
        monitor.checkpoint("baseline")

        // While AX calls to a menu-tracking target may stall, keep every read short (the press element overrides it).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)

        // 1. Restrict with the target hidden.
        let t1 = DispatchTime.now()
        guard apply("A1-hidden", allowTarget: false) else { end(2) }
        while msSince(t1) < 1500 {
            note("neighbour x", neighbourX().map { fmt($0) } ?? "-", t1)
            note("target frame", frameText(targetItem().flatMap { axFrame($0)?.0 }), t1)
            note("target status window", statusWindows(), t1)
            usleep(50_000)
        }
        monitor.checkpoint("restricted A1 +1.5s")
        let hiddenItems = extrasElements(target.pid)
        let hiddenFrame = targetItem().flatMap { axFrame($0)?.0 }
        let nbHidden = neighbourX()
        hiddenConfirmed = neighbour != nil && nbHidden.map { abs($0 - neighbour!.baselineX) > 2 } ?? false
        log.line("RESTRICTED: target AX children=\(hiddenItems.count), frame \(frameText(hiddenFrame)) "
            + "(\(hiddenFrame == baselineFrame ? "STALE: identical to baseline" : "differs from baseline")), status window \(statusWindows()), "
            + "neighbour x \(nbHidden.map { fmt($0) } ?? "-") (baseline \(neighbour.map { fmt($0.baselineX) } ?? "-"), "
            + "shift \(nbHidden.flatMap { x in neighbour.map { fmt(x - $0.baselineX) } } ?? "-")) => hidden confirmed: \(hiddenConfirmed)")

        // 2. Re-apply with the target allowed and poll until it is pressable.
        lastNote = [:]
        let t0 = DispatchTime.now()
        guard apply("A2-allowed", allowTarget: true) else { end(2) }
        var prev: CGRect?
        var pressableMs: Double?
        var element: AXUIElement?
        while msSince(t0) <= 1000 {
            let el = targetItem()
            let f = el.flatMap { axFrame($0)?.0 }
            let nb = neighbourX()
            let nbBack = !hiddenConfirmed || (nb.map { abs($0 - neighbour!.baselineX) <= 2 } ?? false)
            let stable = f != nil && f == prev && isOnScreen(f, displays)
            log.line("\(stamp()) +\(String(format: "%5.0f", msSince(t0))) ms poll: target \(frameText(f)) stable=\(stable) neighbour x=\(nb.map { fmt($0) } ?? "-") back=\(nbBack) status window \(statusWindows())")
            if stable && nbBack {
                pressableMs = msSince(t0)
                element = el
                break
            }
            prev = f
            usleep(50_000)
        }
        if let pressableMs {
            log.line("PRESSABLE after \(String(format: "%.0f", pressableMs)) ms from re-apply (A2 activate)")
        } else {
            log.line("NOT PRESSABLE within 1 s of re-apply: pressing the current element anyway")
            element = targetItem()
        }
        guard let element else { log.line("target item element missing"); end(6) }
        let itemFrame = axFrame(element)?.0 ?? baselineFrame

        // 3. AXPress, then watch for the menu or popover (CG windows and AX).
        let pre = Set(cgWindows(target.pid).filter(\.onscreen).map(\.number))
        lastNote = [:]
        let tp = DispatchTime.now()
        let pressDone = press(element, label: "press")
        var cgOpenMs: Double?, axMenuMs: Double?, axWindowMs: Double?
        let baseAXWindows = axOpenState(nil).windows
        var openWins: [CGWin] = []
        while msSince(tp) < max(options.openHold, 1.0) * 1000 {
            let wins = newWindows(since: pre)
            if !wins.isEmpty && cgOpenMs == nil { cgOpenMs = msSince(tp) }
            if !wins.isEmpty { openWins = wins }
            note("new CG windows", wins.isEmpty ? "none" : wins.map { $0.text + (nearItem($0, itemFrame) ? " NEAR-ITEM" : "") }.joined(separator: "; "), tp)
            let ax = axOpenState(targetItem())
            if ax.hasMenu && axMenuMs == nil { axMenuMs = msSince(tp) }
            if ax.windows > baseAXWindows && axWindowMs == nil { axWindowMs = msSince(tp) }
            note("AX", ax.text, tp)
            usleep(50_000)
        }
        let ms: (Double?) -> String = { $0.map { String(format: "%.0f ms", $0) } ?? "never" }
        let opened = cgOpenMs != nil || axMenuMs != nil || axWindowMs != nil
        log.line("OPEN SIGNALS: CG new window \(ms(cgOpenMs)), AX AXMenu child \(ms(axMenuMs)), AX new AXWindow \(ms(axWindowMs)); press returned: \(pressDone.isSet)")
        log.line("OPENED: \(opened)\(openWins.isEmpty ? "" : " windows " + openWins.map { $0.text + (nearItem($0, itemFrame) ? " NEAR-ITEM" : "") }.joined(separator: "; "))")

        // 4. Re-restrict while it is open.
        if opened {
            lastNote = [:]
            let t3 = DispatchTime.now()
            guard apply("A3-rehidden-while-open", allowTarget: false) else { end(2) }
            var closedMs: Double?
            var last = openWins
            while msSince(t3) < 2000 {
                let wins = newWindows(since: pre)
                if closedMs == nil && !openWins.isEmpty && wins.isEmpty { closedMs = msSince(t3) }
                if !wins.isEmpty { last = wins }
                note("new CG windows", wins.isEmpty ? "none" : wins.map(\.text).joined(separator: "; "), t3)
                note("AX", axOpenState(targetItem()).text, t3)
                note("target frame", frameText(targetItem().flatMap { axFrame($0)?.0 }), t3)
                note("neighbour x", neighbourX().map { fmt($0) } ?? "-", t3)
                note("target status window", statusWindows(), t3)
                usleep(50_000)
            }
            let still = newWindows(since: pre)
            let behaviour: String
            if let closedMs {
                behaviour = "CLOSED \(String(format: "%.0f", closedMs)) ms after the re-restrict"
            } else if openWins.isEmpty {
                behaviour = "no CG window to follow (see AX lines)"
            } else if still.map(\.bounds) == openWins.map(\.bounds) {
                behaviour = "STAYS open, same bounds"
            } else {
                behaviour = "STAYS open but MOVED: \(openWins.map(\.text)) -> \(last.map(\.text))"
            }
            log.line("RE-RESTRICT WHILE OPEN: \(behaviour); press returned: \(pressDone.isSet)")
        }

        // 5. Cleanup: restore the bar, then close whatever is still open.
        invalidateAll()
        usleep(400_000)
        if !newWindows(since: pre).isEmpty {
            let menu = targetItem().flatMap { item in axChildren(item).0.first { axString($0, "AXRole") == "AXMenu" } }
            if let menu {
                let err = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
                log.line("\(stamp()) cleanup: AXCancel on AXMenu -> \(err.rawValue) \(axErrorName(err))")
                usleep(400_000)
            }
            if !newWindows(since: pre).isEmpty, let item = targetItem() {
                log.line("\(stamp()) cleanup: still open, pressing the item again (toggle)")
                _ = press(item, label: "cleanup-press")
                usleep(800_000)
            }
        }
        let left = newWindows(since: pre)
        log.line("cleanup: target windows still open: \(left.isEmpty ? "none" : left.map(\.text).joined(separator: "; ")); first press returned: \(pressDone.isSet)")
        monitor.checkpoint("after cleanup (all invalidated)")
        log.line("neighbour x after cleanup: \(neighbourX().map { fmt($0) } ?? "-") (baseline \(neighbour.map { fmt($0.baselineX) } ?? "-"))")
        log.line("SUMMARY \(options.target): pressable=\(pressableMs.map { String(format: "%.0f ms", $0) } ?? "no (1 s)"), opened=\(opened), "
            + "CG=\(ms(cgOpenMs)) AXMenu=\(ms(axMenuMs)) AXWindow=\(ms(axWindowMs))")
        end(opened ? 0 : 6)
    }
}

/// `press`: baseline scan here (off the main thread), then the timeline on its own thread.
func startPress(_ rest: [String], apps: [AppRef]) {
    guard let options = PressOptions(rest) else {
        log.line("usage: Spike press <bundleID> [--system-items <id,id,...>] [--open-hold <seconds>]")
        finish(64)
    }
    guard let mode = AssessmentMode.resolve() else { finish(4) }
    log.line("press \(options.target), allowedSystemItems=\(options.systemItemsName), openHold=\(options.openHold) s")
    let results = Results()
    DispatchQueue.concurrentPerform(iterations: apps.count) { i in
        results.append(scan(apps[i]))
    }
    let baseline = results.all()
    let run = PressRun(mode: mode, options: options)
    Thread.detachNewThread { run.run(baseline: baseline) }
}

/// `helper [--out <log>] [--t0 <epoch>]`: a tiny status item owner for the launch-after-activate test
/// (SpikeHelper.app, or the bare copy). Logs its own status item window on every change, in ms since --t0.
nonisolated(unsafe) var helperItem: NSStatusItem?  // main thread only
nonisolated(unsafe) var helperLastState = ""

@MainActor
func runHelper() -> Never {
    let helperArgs = Arguments(CommandLine.arguments)
    if let out = helperArgs.outPath { log.open(path: out) }
    let t0 = helperArgs.rest.firstIndex(of: "--t0").flatMap { i in
        i + 1 < helperArgs.rest.count ? Double(helperArgs.rest[i + 1]) : nil
    } ?? Date().timeIntervalSince1970
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Distinct widths, so the probe gap in `hide --launch-helpers` tells the subjects apart.
    let bundleID = Bundle.main.bundleIdentifier
    let item = NSStatusBar.system.statusItem(withLength: bundleID == nil ? 100 : NSStatusItem.variableLength)
    item.button?.title = bundleID == nil ? "SpkBare" : (bundleID == helperBundleID ? "SpkHelp" : "P")
    helperItem = item
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        MainActor.assumeIsolated {
            guard let item = helperItem else { return }
            let w = item.button?.window
            let f = w?.frame ?? .zero
            let state = "isVisible=\(item.isVisible) window=\(w == nil ? "nil" : "x=\(fmt(f.minX)) y=\(fmt(f.minY)) w=\(fmt(f.width)) h=\(fmt(f.height))")"
                + " windowVisible=\(w?.isVisible ?? false) occlusionVisible=\(w?.occlusionState.contains(.visible) ?? false)"
                + " screen=\(w?.screen.map { "\(fmt($0.frame.minX)),\(fmt($0.frame.minY)) \(fmt($0.frame.width))x\(fmt($0.frame.height))" } ?? "nil")"
            if state != helperLastState {
                helperLastState = state
                log.line(String(format: "[%7.1f ms] ", (Date().timeIntervalSince1970 - t0) * 1000)
                    + "pid=\(getpid()) bundleID=\(Bundle.main.bundleIdentifier ?? "nil") " + state)
            }
        }
    }
    // Never outlive a spike run, even if the hide process was killed.
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
    app.run()
    exit(0)
}

// MARK: - Main

if CommandLine.arguments.dropFirst().first == "helper" {
    runHelper()
}

let args = Arguments(CommandLine.arguments)
guard let outPath = args.outPath else {
    FileHandle.standardError.write(Data("usage: Spike <list|hide|press> [args] --out <path>\n".utf8))
    exit(64)
}
log.open(path: outPath)
log.line("Spike \(args.command ?? "-") \(args.rest.joined(separator: " "))")
log.line("pid: \(getpid()), bundle: \(Bundle.main.bundleIdentifier ?? "-"), macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

var trusted = AXIsProcessTrusted()
log.line("AXIsProcessTrusted() == \(trusted)")
if !trusted {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    trusted = AXIsProcessTrustedWithOptions(options)
    log.line("AXIsProcessTrustedWithOptions(prompt: true) == \(trusted)")
}
if !trusted {
    log.line("NOT TRUSTED: turn on Spike (\(Bundle.main.bundlePath)) in System Settings > Privacy & Security > Accessibility, then run again.")
    finish(3)
}

let apps = NSWorkspace.shared.runningApplications.map {
    AppRef(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName)
}
let command = args.command ?? ""
let rest = args.rest

// Commands run off the main thread; main keeps its run loop alive (later subcommands need it).
DispatchQueue.global(qos: .userInitiated).async {
    let status: Int32
    switch command {
    case "list":
        status = runList(apps: apps)
    case "hide":
        startHide(rest, apps: apps)  // finishes itself from the main-queue timeline
        return
    case "press":
        startPress(rest, apps: apps)  // finishes itself from its own timeline thread
        return
    default:
        log.line("unknown command \"\(command)\"; usage: Spike <list|hide|press> [args] --out <path>")
        status = 64
    }
    finish(status)
}

// A run loop with no sources returns at once; a far-future timer keeps it blocking instead of spinning.
RunLoop.main.add(Timer(timeInterval: 1e9, repeats: true) { _ in }, forMode: .default)
RunLoop.main.run()
