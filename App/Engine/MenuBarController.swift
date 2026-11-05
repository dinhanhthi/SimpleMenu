import AppKit
import Observation
import os
import UniformTypeIdentifiers

/// Name and icon of an app that owns (or owned) status items, so the layout UI and the dropdown can render apps
/// that are not running.
struct KnownApp: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage

    var id: String { bundleID }
}

/// The hiding engine: owns the menu bar restriction, the layout, the bar mode and the inventory.
///
/// Call `start(accessibility:)` once at launch and `stop()` in `applicationWillTerminate`. Everything else is
/// driven by `togglePeek()`, `open(bundleID:index:)`, `collapse()` and `setSection(_:for:)`. AX runs only inside
/// `MenuBarInventory`, off the main thread; the restriction calls themselves are synchronous and cheap.
///
/// Measured behaviour of assessment mode (spike 1.4) that this class works around:
/// - While a restriction is active, every unlisted owner is hidden, and an app launched during the restriction
///   gets no layout at all until the next activation. So `didLaunchApplication` always activates a fresh
///   assertion after a 0.3 s debounce (plus a rescan): a newly launched visible app is missing for about that long.
/// - Owners without a bundle ID were NOT hidden: an unbundled process is attributed to its responsible app's
///   bundle ID, and follows that app's section.
/// - Some excluded apps stay visible anyway (a Developer ID helper run from a build dir was never hidden). This is
///   tolerated: no error, no retry.
/// - The activation completion carries no error: a successful `applyAllowedBundleIDs` only means no synchronous
///   failure.
/// - Re-restricting while an item's menu or popover is open leaves it floating, so `.open` never re-restricts on a
///   timer, a launch or a quit; it collapses on an outside click, once the menu has closed, or after a short
///   timeout if none opened.
@MainActor
@Observable
final class MenuBarController {
    /// UserDefaults key of the section new apps get (a `BarSection` raw value). Settings use `@AppStorage` on it.
    static let newAppSectionKey = "NewAppSection"
    /// UserDefaults key of the peek re-hide delay in seconds. Settings use `@AppStorage` on it.
    static let rehideDelayKey = "RehideDelay"

    /// The section new apps get, default visible.
    static var newAppSection: BarSection {
        UserDefaults.standard.string(forKey: newAppSectionKey).flatMap(BarSection.init(rawValue:)) ?? .visible
    }

    /// Seconds before a peek re-hides, default 5.
    static var rehideDelay: TimeInterval {
        let value = UserDefaults.standard.double(forKey: rehideDelayKey)
        return value > 0 ? value : 5
    }

    private(set) var mode: BarMode = .collapsed
    private(set) var layout: Layout
    /// Third-party status items, sorted by `frame.minX`. Frames are only trustworthy for apps allowed in the
    /// current restriction, read at least `layoutDelay` after it was activated: hidden items keep stale (and,
    /// after a re-apply, phantom) frames in AX.
    private(set) var items: [MenuBarItem] = []
    /// Apps whose `items` come from an earlier scan: they are restricted now and the last scan returned none.
    /// Hidden items stay in the AX tree (spike 1.4), so this fallback is rarely hit.
    private(set) var staleBundleIDs: Set<String> = []
    /// Bundle ID -> name and icon, for every app seen in a scan or present in the layout.
    private(set) var knownApps: [String: KnownApp] = [:]
    /// Why hiding is off (private API unavailable or failing), or nil. While set, the bar stays fully expanded.
    private(set) var hidingUnavailableReason: String?
    /// Opt-in snapshots of Hidden items (at peek) and opened items, for the dropdown.
    @ObservationIgnored let capture = MenuBarCapture()
    /// Opt-in on-device suggestions for the layout. Never run by the engine itself.
    @ObservationIgnored let classifier = AppClassifier()

    @ObservationIgnored private let restriction = SMRestriction()
    @ObservationIgnored private let store = LayoutStore()
    @ObservationIgnored private let selfID = Bundle.main.bundleIdentifier ?? "com.math2it.simplemenu"
    @ObservationIgnored private var accessibility: AccessibilityPermission?

    /// The allow-list of the active assertion; nil when none is active.
    @ObservationIgnored private var activeAllowList: [String]?
    /// Set by `didLaunchApplication`: the next apply activates even if the list is unchanged.
    @ObservationIgnored private var needsFreshAssertion = false
    /// In `.open` after a click on a peeked item: the peek allow-list stays, so nothing shifts under the menu.
    @ObservationIgnored private var openKeepsPeekList = false

    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var reapplyTask: Task<Void, Never>?
    @ObservationIgnored private var peekScanTask: Task<Void, Never>?
    @ObservationIgnored private var rehideTask: Task<Void, Never>?
    @ObservationIgnored private var openWatchTask: Task<Void, Never>?
    /// `open(bundleID:index:)`: waits for the fresh frame, then clicks. Separate from `openWatchTask`, which
    /// `beginOpen` cancels.
    @ObservationIgnored private var openClickTask: Task<Void, Never>?
    @ObservationIgnored private var mouseMonitor: Any?
    /// Created on the first open; `configureDropdown(anchor:onSettings:)` supplies what it needs.
    @ObservationIgnored private var dropdown: DropdownPanel?
    /// The status item button's window frame (screen coordinates), the dropdown's anchor.
    @ObservationIgnored private var dropdownAnchor: (() -> NSRect?)?
    @ObservationIgnored private var dropdownOnSettings: () -> Void = {}
    #if DEBUG
    /// The last dropdown open, until the next scan merges: logs trigger -> rescan done.
    @ObservationIgnored private var dropdownOpenedAt: ContinuousClock.Instant?
    #endif
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    /// Set once the peek's layout delay has passed: scans started from then on read fresh frames.
    @ObservationIgnored private var peekScanStarted = false
    /// True once such a scan has merged: only then are peeked frames hit-tested.
    @ObservationIgnored private var peekFramesReady = false
    /// A peek click that came before `peekFramesReady`, decided once the frames are fresh.
    @ObservationIgnored private var pendingPeekClick: PendingClick?
    @ObservationIgnored private var openTarget: OpenTarget?

    /// From activation to a laid-out, pressable item: 87–211 ms measured (spike 1.4).
    private static let layoutDelay: Duration = .milliseconds(250)
    private static let reapplyDebounce: Duration = .milliseconds(300)
    /// `.open` only: how long to wait for the opened item's menu or popover window.
    private static let openTimeout: Duration = .seconds(3)
    private static let openPollInterval: Duration = .milliseconds(250)
    private static let logger = Logger(subsystem: "com.math2it.simplemenu", category: "MenuBar")

    private struct PendingClick {
        let point: CGPoint
        let baseline: Set<CGWindowID>
    }

    /// The app whose item was clicked, with the on-screen windows from just before the click.
    private struct OpenTarget {
        let bundleID: String
        let pid: pid_t
        let itemFrame: CGRect
        let baseline: Set<CGWindowID>
    }

    private struct WindowInfo: Sendable {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
    }

    init() {
        layout = store.load()
    }

    // MARK: - API

    /// Starts the engine: one full scan, then collapse when AX is trusted and the private API is available.
    /// A later Accessibility grant scans and collapses without a relaunch. Call once.
    func start(accessibility: AccessibilityPermission) {
        guard self.accessibility == nil else { return }
        self.accessibility = accessibility
        if !SMRestriction.isAvailable() {
            failSoft(SMRestriction.unavailableReason ?? "The menu bar restriction API is unavailable")
        } else if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            // Measured on macOS 27.0.1: run from elsewhere (e.g. ~/Downloads), an app's items are hidden even when
            // allow-listed, SimpleMenu's own icon included, which would leave no way to peek.
            failSoft("Move SimpleMenu to the Applications folder: run from elsewhere, macOS hides its own icon too.")
        }
        observeWorkspace()
        observeTrust()
        Task {
            await rescan()
            apply()
        }
    }

    /// Removes the restriction; the full bar returns. Call from `applicationWillTerminate`.
    func stop() {
        endPeekAndOpen()
        reapplyTask?.cancel()
        restriction.clear()
        activeAllowList = nil
    }

    /// Collapsed: peeks (shows hidden apps until `RehideDelay`, a click elsewhere, or the peeked item's menu
    /// closing). Peek or open: collapses. The mode flips at once; the rescan for fresh frames follows.
    func togglePeek() {
        guard mode == .collapsed else {
            collapse()
            return
        }
        mode = .peek
        apply()
        installMouseMonitor()
        let delay = Self.rehideDelay
        rehideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.mode == .peek else { return }
            self.collapse()
        }
        peekScanTask = Task { [weak self] in
            try? await Task.sleep(for: Self.layoutDelay)
            guard !Task.isCancelled, let self, self.mode == .peek else { return }
            // Any scan from here on started after the layout delay, so its frames are fresh.
            self.peekScanStarted = true
            await self.rescan()
        }
    }

    /// Opens item `index` of `bundleID` (a Hidden or Always-hidden app, from the dropdown): closes the dropdown,
    /// allows that app on top of the collapsed list, waits for a fresh frame, then posts one real left click at the
    /// item's centre, like the user's own click, puts the pointer back and follows the `.open` close rules. A click,
    /// not AXPress: AXPress cannot open a SwiftUI `MenuBarExtra(.window)` item (measured on macOS 27), and a click
    /// is what NSMenu and popover items get from the user too. Frames are polled only from `layoutDelay` on: a
    /// hidden item's stale frame is stable and on-screen too. Collapses (and logs) if the item never gets a fresh
    /// frame. The click is posted only once the live gate holds (fresh AX reads of the item and of the other allowed
    /// apps' items, never cached frames); otherwise it logs and lets the open watch time out. The click lands inside
    /// `openTarget.itemFrame`, which `globalClick` ignores, so it is not taken for an outside click. The item's
    /// frame must also lie in a menu bar strip: the app reports it itself, and a click elsewhere is never posted.
    func open(bundleID: String, index: Int) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            Self.logger.error("open: \(bundleID, privacy: .public) is not running")
            return
        }
        closeDropdown()
        endPeekAndOpen()
        mode = .open(bundleID)
        apply()
        installMouseMonitor()
        let strips = Self.menuBarStrips()
        openClickTask = Task { [weak self] in
            // `start` is when the `apply()` that allowed the item returned.
            let start = ContinuousClock.now
            try? await Task.sleep(for: Self.layoutDelay)
            guard !Task.isCancelled else { return }
            let item = await MenuBarInventory.waitForFreshFrame(bundleID: bundleID, index: index, strips: strips)
            guard !Task.isCancelled, let self, self.mode == .open(bundleID) else { return }
            guard let item else {
                Self.logger.error("""
                    open: no fresh frame in the menu bar for \(bundleID, privacy: .public) #\(index, privacy: .public)
                    """)
                self.collapse()
                return
            }
            self.captureSnapshots([item])
            let fresh = ContinuousClock.now - start
            let baseline = await Task.detached { Set(Self.onScreenWindows().map(\.id)) }.value
            guard !Task.isCancelled, self.mode == .open(bundleID) else { return }
            self.beginOpen(item, baseline: baseline)
            let reason = await self.clickBlockedReason(item, allowed: start, strips: strips)
            // After a collapse the item keeps a stale frame that passes the gate: check the mode last, with no await
            // before the click.
            guard !Task.isCancelled, self.mode == .open(bundleID), self.openTarget?.itemFrame == item.frame else {
                return
            }
            if let reason {
                Self.logger.error("""
                    open: no click on \(bundleID, privacy: .public) #\(index, privacy: .public): \
                    \(reason, privacy: .public)
                    """)
                return
            }
            let clickStart = ContinuousClock.now
            await MenuBarInventory.click(at: CGPoint(x: item.frame.midX, y: item.frame.midY))
            #if DEBUG
            let posted = ContinuousClock.now - clickStart
            Self.logger.notice("""
                open: clicked \(bundleID, privacy: .public) #\(index, privacy: .public): fresh frame after \
                \(fresh, privacy: .public), click posted in \(posted, privacy: .public)
                """)
            #else
            _ = (fresh, clickStart)
            #endif
        }
    }

    /// Why the live gate blocks a click on `item` now, or nil: the item must be allowed at least `layoutDelay`
    /// ago (`allowed`), and `MenuBarInventory.notLaidOutReason` must pass on fresh AX reads of the item and of the
    /// other allowed apps' items, never cached frames.
    private func clickBlockedReason(_ item: MenuBarItem, allowed: ContinuousClock.Instant,
                                    strips: [CGRect]) async -> String? {
        // Holds by construction (layout delay, then the fresh-frame wait); kept explicit because an item is laid out
        // only 87–211 ms after the activation (spike 1.4), and before that its frame is stale.
        let sinceAllowed = ContinuousClock.now - allowed
        if sinceAllowed < Self.layoutDelay { return "allowed only \(sinceAllowed) ago" }
        // Only allowed apps (SimpleMenu included): restricted ones keep stale or phantom frames.
        let others = NSWorkspace.shared.runningApplications.compactMap { app -> (pid: pid_t, bundleID: String)? in
            guard let id = app.bundleIdentifier, app.processIdentifier != item.pid, !isRestricted(id) else {
                return nil
            }
            return (app.processIdentifier, id)
        }
        return await MenuBarInventory.notLaidOutReason(item, others: others, strips: strips)
    }

    /// Set once by `StatusItemController`: the button's window frame to anchor under, and what "Settings…" runs.
    func configureDropdown(anchor: @escaping () -> NSRect?, onSettings: @escaping () -> Void) {
        dropdownAnchor = anchor
        dropdownOnSettings = onSettings
    }

    var isDropdownVisible: Bool { dropdown?.isVisible ?? false }

    /// Opens the dropdown under SimpleMenu's icon from the cached inventory (its rescan follows), or closes it.
    /// Opening or closing never changes `mode`: a peek or an open item stays as it is.
    func toggleDropdown() {
        if isDropdownVisible { return closeDropdown() }
        let start = ContinuousClock.now
        guard let frame = dropdownAnchor?() else {
            Self.logger.error("dropdown: no status item to anchor under")
            return
        }
        let panel = dropdown ?? DropdownPanel(controller: self, buttonFrame: { [weak self] in self?.dropdownAnchor?() },
                                               onSettings: dropdownOnSettings)
        dropdown = panel
        panel.show(below: frame)
        #if DEBUG
        dropdownOpenedAt = start
        let elapsed = ContinuousClock.now - start
        Self.logger.notice("""
            dropdown: visible \(panel.isVisible, privacy: .public) after \(elapsed, privacy: .public) \
            with \(self.items.count, privacy: .public) cached items
            """)
        #else
        _ = start
        #endif
    }

    /// Closes the dropdown panel, if shown (before an item opens, a second toggle, a click on SimpleMenu).
    func closeDropdown() {
        guard isDropdownVisible else { return }
        dropdown?.close()
    }

    /// Starts a rescan off the main thread; `items` and `knownApps` update when it ends. For the dropdown, which
    /// shows the cached inventory first.
    func rescanInBackground() {
        Task { await rescan() }
    }

    /// Back to the collapsed layout; ends any peek or open.
    func collapse() {
        endPeekAndOpen()
        mode = .collapsed
        apply()
    }

    /// Moves one app to `section`, saves the layout and applies it at once.
    func setSection(_ section: BarSection, for bundleID: String) {
        guard layout.sections[bundleID] != section else { return }
        layout.sections[bundleID] = section
        store.save(layout)
        refreshKnownApps([bundleID])
        apply()
    }

    // MARK: - Restriction

    /// Restricts the bar to `allowedBundleIDs` for the current mode, skipping an unchanged list. With nothing to
    /// hide, it clears instead of activating an allow-everything assertion, so no unlisted owner is hidden.
    private func apply() {
        guard hidingUnavailableReason == nil, accessibility?.isTrusted == true else {
            clearRestriction()
            return
        }
        let running = runningBundleIDs()
        let listMode: BarMode = openKeepsPeekList ? .peek : mode
        let allowed = allowedBundleIDs(running: running, layout: layout, mode: listMode, selfID: selfID)
        guard !Set(running).isSubset(of: allowed) else {
            clearRestriction()
            return
        }
        guard needsFreshAssertion || allowed != activeAllowList else { return }
        do {
            try restriction.applyAllowedBundleIDs(allowed)
            activeAllowList = allowed
            needsFreshAssertion = false
        } catch {
            failSoft(error.localizedDescription)
        }
    }

    private func clearRestriction() {
        restriction.clear()
        activeAllowList = nil
        needsFreshAssertion = false
    }

    /// Hiding off for this run: the bar stays expanded and the reason is shown. A failed apply leaves the previous
    /// assertion active, hence the clear.
    private func failSoft(_ reason: String) {
        Self.logger.error("hiding unavailable: \(reason, privacy: .public)")
        clearRestriction()
        hidingUnavailableReason = reason
    }

    private func runningBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }

    private func isRestricted(_ bundleID: String) -> Bool {
        activeAllowList.map { !$0.contains(bundleID) } ?? false
    }

    // MARK: - Observers

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let launch = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReapply(freshAssertion: true) }
        }
        let terminate = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReapply(freshAssertion: false) }
        }
        workspaceObservers = [launch, terminate]
    }

    /// A launched app has no layout until the next activation, so a launch always activates a fresh assertion.
    /// While `.open`, the apply waits for `collapse()`.
    private func scheduleReapply(freshAssertion: Bool) {
        if freshAssertion { needsFreshAssertion = true }
        reapplyTask?.cancel()
        reapplyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reapplyDebounce)
            guard !Task.isCancelled, let self else { return }
            if case .open = self.mode {
                // A menu or popover in use is never re-restricted; `needsFreshAssertion` stays set for `collapse()`.
            } else {
                self.apply()
            }
            try? await Task.sleep(for: Self.layoutDelay)
            guard !Task.isCancelled else { return }
            await self.rescan()
        }
    }

    /// One-shot tracking, re-registered on every change. A late grant scans, then applies, with no relaunch.
    private func observeTrust() {
        guard let accessibility else { return }
        withObservationTracking {
            _ = accessibility.isTrusted
        } onChange: { [weak self] in
            Task { @MainActor in self?.trustChanged() }
        }
    }

    private func trustChanged() {
        observeTrust()
        guard accessibility?.isTrusted == true else { return }
        Task {
            await rescan()
            apply()
        }
    }

    // MARK: - Inventory

    /// Scans, merges, refreshes the known apps and gives unseen apps the `NewAppSection` default. A layout change
    /// is saved and applied (an app launched while collapsed is allowed as unassigned, then hidden here); while
    /// `.open`, `collapse()` applies it.
    private func rescan() async {
        scanGeneration += 1
        let generation = scanGeneration
        let start = ContinuousClock.now
        let scanned = await MenuBarInventory.scan()
        guard generation == scanGeneration else { return }
        #if DEBUG
        let elapsed = ContinuousClock.now - start
        Self.logger.notice("scan: \(scanned.count, privacy: .public) items in \(elapsed, privacy: .public)")
        #else
        _ = start
        #endif
        merge(scanned)
        #if DEBUG
        if let opened = dropdownOpenedAt {
            dropdownOpenedAt = nil
            let elapsed = ContinuousClock.now - opened
            Self.logger.notice("dropdown: rescan done after \(elapsed, privacy: .public)")
        }
        #endif
        if mode == .peek, peekScanStarted, !peekFramesReady {
            peekFramesReady = true
            // Always-hidden apps stay restricted in a peek, so they are captured only when opened.
            captureSnapshots(items.filter {
                layout.sections[$0.bundleID] == .hidden && !staleBundleIDs.contains($0.bundleID)
            })
            if let click = pendingPeekClick {
                pendingPeekClick = nil
                peekClick(at: click.point, baseline: click.baseline)
            }
        }
        var seen: [String] = []
        for item in scanned where !seen.contains(item.bundleID) {
            seen.append(item.bundleID)
        }
        let assigned = assignNewApps(seen: seen, layout: layout, default: Self.newAppSection)
        refreshKnownApps(seen + Array(assigned.sections.keys))
        guard assigned != layout else { return }
        layout = assigned
        store.save(layout)
        if case .open = mode { return }
        apply()
    }

    /// A scan never simply replaces the cache: a running app outside the active allow-list that returned no
    /// items keeps its last-seen ones, flagged stale.
    private func merge(_ scanned: [MenuBarItem]) {
        let scannedIDs = Set(scanned.map(\.bundleID))
        let running = Set(runningBundleIDs())
        var merged = scanned
        var stale: Set<String> = []
        for item in items
        where !scannedIDs.contains(item.bundleID) && isRestricted(item.bundleID) && running.contains(item.bundleID) {
            merged.append(item)
            stale.insert(item.bundleID)
        }
        items = merged.sorted { $0.frame.minX < $1.frame.minX }
        staleBundleIDs = stale
    }

    /// Adds apps not yet cached: name and icon from the running app, else from its bundle on disk.
    private func refreshKnownApps(_ bundleIDs: [String]) {
        for id in bundleIDs where knownApps[id] == nil {
            knownApps[id] = Self.resolveApp(id)
        }
    }

    private static func resolveApp(_ bundleID: String) -> KnownApp {
        let workspace = NSWorkspace.shared
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
            return KnownApp(bundleID: bundleID, name: app.localizedName ?? bundleID, icon: icon)
        }
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            return KnownApp(bundleID: bundleID, name: url.deletingPathExtension().lastPathComponent,
                            icon: workspace.icon(forFile: url.path))
        }
        return KnownApp(bundleID: bundleID, name: bundleID, icon: workspace.icon(for: .applicationBundle))
    }

    // MARK: - Snapshots

    /// Opt-in (`CaptureSnapshots`, default off, read on every call): captures those of `items` that are allowed now
    /// and in a menu bar strip, in the background. `items` must have fresh frames. Never awaited, so it never delays
    /// a click.
    private func captureSnapshots(_ items: [MenuBarItem]) {
        guard UserDefaults.standard.bool(forKey: MenuBarCapture.settingKey) else {
            #if DEBUG
            Self.logger.notice("capture: skipped, \(MenuBarCapture.settingKey, privacy: .public) is off")
            #endif
            return
        }
        let strips = Self.menuBarStrips()
        let laidOut = items.filter { item in
            !isRestricted(item.bundleID) && isInMenuBarStrip(item.frame, strips: strips)
        }
        guard !laidOut.isEmpty else { return }
        Task { await capture.capture(laidOut) }
    }

    // MARK: - Peek and open

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Screen coordinates (bottom-left origin) for a global event.
            let location = event.locationInWindow
            MainActor.assumeIsolated { self?.globalClick(at: location) }
        }
    }

    /// Frame hit-tests only, plus one window-list read when it matters; no AX. The monitor sees clicks on
    /// SimpleMenu's own status button too (macOS 27): those are left to `StatusItemController.clicked`, which
    /// collapses on mouse-up, so the mouse-down does not collapse and the mouse-up peek again.
    private func globalClick(at location: CGPoint) {
        if let button = dropdownAnchor?(), button.contains(location) { return }
        let point = Self.topLeft(location)
        switch mode {
        case .collapsed:
            return
        case .peek:
            guard peekFramesReady else {
                // Peeked frames are stale until the rescan: decide then, with the windows from now.
                if pendingPeekClick == nil {
                    pendingPeekClick = PendingClick(point: point, baseline: Set(Self.onScreenWindows().map(\.id)))
                }
                return
            }
            guard let item = peekedItem(at: point) else { return collapse() }
            openPeeked(item, baseline: Set(Self.onScreenWindows().map(\.id)))
        case .open:
            guard let target = openTarget else { return collapse() }
            if target.itemFrame.contains(point) { return }
            let windows = Self.onScreenWindows()
            if windows.contains(where: { $0.pid == target.pid && $0.bounds.contains(point) }) { return }
            if openKeepsPeekList, let item = peekedItem(at: point) {
                // Another peeked item: its menu replaces b's, and the peek list still stands.
                beginOpen(item, baseline: Set(windows.map(\.id)))
                return
            }
            collapse()
        }
    }

    /// In peek: a click on a peeked item keeps the peek list and switches to the `.open` close rules
    /// (no re-apply, so the neighbours do not vanish and shift the item while its menu opens). Elsewhere: collapse.
    private func peekClick(at point: CGPoint, baseline: Set<CGWindowID>) {
        guard let item = peekedItem(at: point) else { return collapse() }
        openPeeked(item, baseline: baseline)
    }

    private func openPeeked(_ item: MenuBarItem, baseline: Set<CGWindowID>) {
        rehideTask?.cancel()
        openKeepsPeekList = true
        beginOpen(item, baseline: baseline)
    }

    /// An item shown by the active restriction, with a fresh frame, under `point`.
    private func peekedItem(at point: CGPoint) -> MenuBarItem? {
        items.first { item in
            item.frame != .zero && !staleBundleIDs.contains(item.bundleID)
                && !isRestricted(item.bundleID) && item.frame.contains(point)
        }
    }

    /// Enters `.open(bundleID)` without applying, and watches the item's windows: collapse once its menu or
    /// popover has closed, or after `openTimeout` if none appeared. No re-hide timer.
    /// The caller picks the allow-list first: a peek click sets `openKeepsPeekList`; `open(bundleID:index:)` leaves
    /// it false and calls `apply()` after setting the mode, so `collapsed + b` is used. `baseline` must be the
    /// on-screen window IDs from before the click.
    private func beginOpen(_ item: MenuBarItem, baseline: Set<CGWindowID>) {
        let target = OpenTarget(bundleID: item.bundleID, pid: item.pid, itemFrame: item.frame, baseline: baseline)
        openTarget = target
        mode = .open(item.bundleID)
        openWatchTask?.cancel()
        openWatchTask = Task { [weak self] in
            let start = ContinuousClock.now
            var sawWindow = false
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.openPollInterval)
                let windows = await Task.detached { Self.onScreenWindows() }.value
                guard !Task.isCancelled, let self, case .open = self.mode else { return }
                let opened = windows.contains { $0.pid == target.pid && !target.baseline.contains($0.id) }
                if opened {
                    #if DEBUG
                    if !sawWindow {
                        let elapsed = ContinuousClock.now - start
                        Self.logger.notice("""
                            open: \(target.bundleID, privacy: .public) window on-screen after \(elapsed, privacy: .public)
                            """)
                    }
                    #endif
                    sawWindow = true
                } else if sawWindow || ContinuousClock.now - start >= Self.openTimeout {
                    #if DEBUG
                    let outcome = sawWindow ? "closed" : "no window within the timeout"
                    Self.logger.notice("open: \(target.bundleID, privacy: .public) \(outcome, privacy: .public), collapsing")
                    #endif
                    self.collapse()
                    return
                }
            }
        }
    }

    private func endPeekAndOpen() {
        rehideTask?.cancel()
        peekScanTask?.cancel()
        openWatchTask?.cancel()
        openClickTask?.cancel()
        rehideTask = nil
        peekScanTask = nil
        openWatchTask = nil
        openClickTask = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        peekScanStarted = false
        peekFramesReady = false
        pendingPeekClick = nil
        openTarget = nil
        openKeepsPeekList = false
    }

    // MARK: - Geometry

    /// Bottom-left screen point to the top-left global space of AX frames and CG window bounds (primary display).
    private static func topLeft(_ point: CGPoint) -> CGPoint {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: height - point.y)
    }

    /// Each display's menu bar strip (top-left global, like AX frames), with 1 pt above and 2 pt below as slack,
    /// for `isInMenuBarStrip`. The bar's height is the screen's top inset (covers notched displays), else
    /// `NSStatusBar.system.thickness`. Reads NSScreen, so main actor only.
    private static func menuBarStrips() -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            let bounds = CGDisplayBounds(id)
            let inset = screen.frame.maxY - screen.visibleFrame.maxY
            let height = inset > 0 ? inset : NSStatusBar.system.thickness
            return CGRect(x: bounds.minX, y: bounds.minY - 1, width: bounds.width, height: height + 3)
        }
    }

    /// On-screen windows with their owner and bounds (top-left global). Thread-safe; needs no Screen Recording.
    private nonisolated static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return WindowInfo(id: id, pid: pid, bounds: bounds)
        }
    }
}
