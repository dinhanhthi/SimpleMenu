// The dropdown's content: the running Hidden and Always-hidden apps with their status items, and a Settings button;
// or, as a bar, one icon per item.
import AppKit
import SwiftUI

/// Reads the controller's cached `items`, `layout`, `knownApps` only (no AX), so it renders at once; a
/// rescan updates the rows in place. Reports its size through `onSize` so the panel can keep its top edge pinned.
struct DropdownView: View {
    let controller: MenuBarController
    let style: DropdownStyle
    /// Bundle ID and item index of a clicked row.
    let onOpen: (String, Int) -> Void
    let onSettings: () -> Void
    let onSize: (CGSize) -> Void

    /// The list scrolls past this height.
    private static let maxListHeight: CGFloat = 480

    var body: some View {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let groups = [BarSection.hidden, .alwaysHidden].map { ($0, entries(in: $0, running: running)) }
            .filter { !$0.1.isEmpty }
        switch style {
        case .dropdown: list(groups)
        case .bar: BarCard(groups: groups, onOpen: onOpen, onSize: onSize)
        }
    }

    private func list(_ groups: [(BarSection, [AppEntry])]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                EmptyState()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups, id: \.0) { group in
                            SectionGroup(title: group.0.title, apps: group.1, onOpen: onOpen)
                        }
                    }
                    .padding(6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Self.maxListHeight)
            }
            Divider()
            Button(action: onSettings) {
                Label("Settings…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(DropdownRowStyle())
            .padding(6)
        }
        .frame(width: 300)
        .modifier(GlassCard(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The running apps of `section`: those with cached items in menu bar order, then those without (launched
    /// after the collapse, so never scanned) by name.
    private func entries(in section: BarSection, running: Set<String>) -> [AppEntry] {
        let ids = Set(controller.layout.sections.filter { $0.value == section }.keys).intersection(running)
        var order: [String] = []
        var itemsByApp: [String: [MenuBarItem]] = [:]
        for item in controller.items where ids.contains(item.bundleID) {
            if itemsByApp[item.bundleID] == nil { order.append(item.bundleID) }
            itemsByApp[item.bundleID, default: []].append(item)
        }
        let withItems = order.map { entry($0, items: itemsByApp[$0, default: []].sorted { $0.index < $1.index }) }
        let withoutItems = ids.subtracting(order).map { entry($0, items: []) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return withItems + withoutItems
    }

    /// Name and icon from the known-apps cache (taken from `NSRunningApplication` for a running app), else from the
    /// running app itself.
    private func entry(_ bundleID: String, items: [MenuBarItem]) -> AppEntry {
        if let known = controller.knownApps[bundleID] {
            return AppEntry(bundleID: bundleID, name: known.name, icon: known.icon, items: items)
        }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        return AppEntry(bundleID: bundleID, name: app?.localizedName ?? bundleID,
                        icon: app?.icon ?? NSWorkspace.shared.icon(for: .applicationBundle), items: items)
    }
}

/// One app of a group and its cached status items (none if it was never scanned).
private struct AppEntry: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage
    let items: [MenuBarItem]

    var id: String { bundleID }
}

/// "Hidden" or "Always hidden": a caption, then each app.
private struct SectionGroup: View {
    let title: String
    let apps: [AppEntry]
    let onOpen: (String, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ForEach(apps) { app in
                AppRows(app: app, onOpen: onOpen)
            }
        }
    }
}

/// An app with at most one item is a single row (icon, name, item text); one with several is an app header over
/// one row per item. An app with no cached items opens its first item.
private struct AppRows: View {
    let app: AppEntry
    let onOpen: (String, Int) -> Void

    var body: some View {
        if app.items.count <= 1 {
            let index = app.items.first?.index ?? 0
            Button { onOpen(app.bundleID, index) } label: {
                AppLabel(app: app, text: app.items.first.flatMap(Self.text))
            }
            .buttonStyle(DropdownRowStyle())
        } else {
            AppLabel(app: app, text: nil)
                .padding(.horizontal, DropdownRowStyle.padding)
                .padding(.vertical, 4)
            ForEach(app.items, id: \.rowID) { item in
                Button { onOpen(app.bundleID, item.index) } label: {
                    Text(Self.text(item) ?? "Item \(item.index + 1)")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, AppLabel.iconSize + AppLabel.spacing)
                }
                .buttonStyle(DropdownRowStyle())
            }
        }
    }

    /// AXTitle, else AXDescription (or its fallbacks).
    fileprivate static func text(_ item: MenuBarItem) -> String? {
        item.title ?? item.detail
    }
}

private struct AppLabel: View {
    static let iconSize: CGFloat = 20
    static let spacing: CGFloat = 8

    let app: AppEntry
    let text: String?

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                if let text {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Nothing is hidden")
                .font(.headline)
            Text("Move apps to Hidden or Always hidden in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
    }
}

/// The bar: one row of icons, Hidden then Always hidden with a divider between, scrolling sideways past the panel's
/// width cap. Reports the row's own width, not the clipped one, so the panel grows back when there is room; the
/// height is the card's, which a legacy scroller adds to.
private struct BarCard: View {
    let groups: [(BarSection, [AppEntry])]
    let onOpen: (String, Int) -> Void
    let onSize: (CGSize) -> Void

    @State private var contentWidth: CGFloat = 0
    @State private var hintWidth: CGFloat = 0
    @State private var height: CGFloat = 0

    var body: some View {
        Group {
            if groups.isEmpty {
                Text("Nothing is hidden")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DropdownRowStyle.padding)
                    .frame(height: BarIcon.height)
                    .padding(6)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report(width: $0) }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            ForEach(groups, id: \.0) { group in
                                if group.0 != groups.first?.0 {
                                    Divider()
                                        .frame(height: AppLabel.iconSize)
                                        .padding(.horizontal, 4)
                                }
                                ForEach(group.1) { app in
                                    BarAppIcons(app: app, onOpen: onOpen)
                                }
                            }
                        }
                        .padding(6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report(width: $0) }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // The icons show no live value (hidden items are not drawn): say where to see it.
                    Text("Click an icon to see its live status in the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.bottom, 7)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report(hintWidth: $0) }
                }
            }
        }
        .modifier(GlassCard(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report(height: $0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The panel's size: the wider of the icon row and the hint (a short row would clip the hint), and the card's
    /// height.
    private func report(width: CGFloat? = nil, hintWidth: CGFloat? = nil, height: CGFloat? = nil) {
        if let width { contentWidth = width }
        if let hintWidth { self.hintWidth = hintWidth }
        if let height { self.height = height }
        onSize(CGSize(width: max(contentWidth, self.hintWidth), height: self.height))
    }
}

/// An app's icons in the bar: one per cached item, or one opening its first item if it has none, like `AppRows`.
private struct BarAppIcons: View {
    let app: AppEntry
    let onOpen: (String, Int) -> Void

    var body: some View {
        if app.items.count <= 1 {
            BarIcon(app: app, label: app.name) { onOpen(app.bundleID, app.items.first?.index ?? 0) }
        } else {
            ForEach(app.items, id: \.rowID) { item in
                let text = AppRows.text(item) ?? "Item \(item.index + 1)"
                BarIcon(app: app, label: "\(app.name): \(text)") { onOpen(app.bundleID, item.index) }
            }
        }
    }
}

/// An app icon button; its tooltip and VoiceOver label name the app (and the item, for an app with several).
private struct BarIcon: View {
    /// The icon and `DropdownRowStyle`'s vertical padding.
    static let height = AppLabel.iconSize + 10

    let app: AppEntry
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: AppLabel.iconSize, height: AppLabel.iconSize)
        }
        .buttonStyle(DropdownRowStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A full-width row: a rounded `Palette.hoverFill` on hover, `Palette.pressedFill` while pressed. The hover fades
/// with `Motion.hover`, instantly under Reduce Motion.
private struct DropdownRowStyle: ButtonStyle {
    static let padding: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            configuration.label
                .padding(.horizontal, DropdownRowStyle.padding)
                .padding(.vertical, 5)
                .background(shape.fill(configuration.isPressed ? Palette.pressedFill
                    : hovered ? Palette.hoverFill : .clear))
                .contentShape(shape)
                .animation(reduceMotion ? nil : Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

private extension MenuBarItem {
    /// Unique within a scan: one bundle ID can own several processes, each numbering its items from 0.
    var rowID: String { "\(bundleID)#\(pid)#\(index)" }
}
