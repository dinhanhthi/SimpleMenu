// The Menu Bar Layout section: one column per bar section, app cards dragged between them.
import AppKit
import SwiftUI

/// Reads the controller's `layout` and `knownApps` in `body` (no AX, no disk), so a change from anywhere (a drop,
/// a DEBUG `setSection`, a rescan) shows at once. A drop calls `setSection(_:for:)`, which saves and applies.
struct LayoutSettingsView: View {
    @Environment(MenuBarController.self) private var menuBar: MenuBarController?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Running bundle IDs, kept current by the workspace notifications: the section stays alive once opened.
    @State private var running = Self.runningBundleIDs()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drag apps between the columns. Hidden apps show on a click on SimpleMenu; always hidden ones only "
                + "in its Option-click list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                ForEach(BarSection.allCases, id: \.self) { section in
                    LayoutColumn(section: section, cards: cards(in: section), onDrop: move)
                }
            }
            .animation(animation, value: menuBar?.layout)
            .animation(animation, value: running)
        }
        // Level with the sidebar card, which has the same insets.
        .padding(.top, 4)
        .padding([.horizontal, .bottom], 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didLaunchApplicationNotification)) { _ in running = Self.runningBundleIDs() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didTerminateApplicationNotification)) { _ in running = Self.runningBundleIDs() }
    }

    private var animation: Animation? { reduceMotion ? nil : Motion.standard }

    /// Only bundle IDs already in the layout move: a drop is untrusted text and may come from another app.
    private func move(_ bundleIDs: [String], to section: BarSection) -> Bool {
        guard let menuBar else { return false }
        let known = bundleIDs.filter { menuBar.layout.sections[$0] != nil }
        for id in known { menuBar.setSection(section, for: id) }
        return !known.isEmpty
    }

    /// The apps of `section` by name, so a drop never reshuffles the column.
    private func cards(in section: BarSection) -> [LayoutCard] {
        guard let menuBar else { return [] }
        return menuBar.layout.sections.filter { $0.value == section }.keys
            .map { card($0, known: menuBar.knownApps[$0]) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Name and icon from the known-apps cache, else from the running app (before the first scan).
    private func card(_ bundleID: String, known: KnownApp?) -> LayoutCard {
        let isRunning = running.contains(bundleID)
        if let known {
            return LayoutCard(bundleID: bundleID, name: known.name, icon: known.icon, isRunning: isRunning)
        }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        return LayoutCard(bundleID: bundleID, name: app?.localizedName ?? bundleID,
                          icon: app?.icon ?? NSWorkspace.shared.icon(for: .applicationBundle), isRunning: isRunning)
    }

    private static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

/// One app of the layout.
private struct LayoutCard: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage
    let isRunning: Bool

    var id: String { bundleID }
}

/// A section's title and its cards, on a solid card that takes the drops; highlighted while a drag is over it.
private struct LayoutColumn: View {
    let section: BarSection
    let cards: [LayoutCard]
    /// Returns whether the drop moved anything.
    let onDrop: ([String], BarSection) -> Bool
    @State private var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(section.title).font(.headline)
                Spacer(minLength: 4)
                Text("\(cards.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 4)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(cards) { card in
                        AppCard(card: card, section: section, onMove: { _ = onDrop([card.bundleID], $0) })
                    }
                    if cards.isEmpty {
                        Text("Drop apps here")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(GlassCard(cornerRadius: 14))
        .overlay(shape.fill(targeted ? Palette.hoverFill : .clear).allowsHitTesting(false))
        .animation(reduceMotion ? nil : Motion.hover, value: targeted)
        // The whole column takes drops, empty space included.
        .contentShape(shape)
        .dropDestination(for: String.self) { ids, _ in onDrop(ids, section) } isTargeted: { targeted = $0 }
    }
}

/// An app's icon and name, dimmed and labelled when it is not running; the whole card is the drag handle.
private struct AppCard: View {
    let card: LayoutCard
    let section: BarSection
    /// The non-drag path (VoiceOver actions).
    let onMove: (BarSection) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 8) {
            Image(nsImage: card.icon)
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.name).lineLimit(1)
                if !card.isRunning {
                    Text("not running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(shape.fill(Palette.inputSurface))
        .opacity(card.isRunning ? 1 : 0.5)
        .contentShape(shape)
        .draggable(card.bundleID)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            ForEach(BarSection.allCases.filter { $0 != section }, id: \.self) { other in
                Button("Move to \(other.title)") { onMove(other) }
            }
        }
    }
}
