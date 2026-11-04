// The Settings page, sidebar layout: the sections in a raised card, the selected one's form on the right over the
// window's glass; each change is saved at once.
import AppKit
import ServiceManagement
import SwiftUI

/// The Settings page `MainView` shows; the tab layout defines the same name.
typealias SettingsRoot = SettingsSidebarView

/// A sidebar section. Adding one: a case, its row in `label`, its form in `SettingsSidebarView.content`.
enum SettingsSection: CaseIterable, Identifiable {
    case general, permissions, about

    var id: Self { self }

    var label: (title: String, icon: String) {
        switch self {
        case .general: ("General", "gearshape")
        case .permissions: ("Permissions", "hand.raised")
        case .about: ("About", "info.circle")
        }
    }
}

struct SettingsSidebarView: View {
    /// The selected section, shared with the AppDelegate so a menu can open a section.
    @Bindable var navigation: Navigation
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.defaultMode
    /// Sections opened so far: kept alive like TabView's tabs, so a section keeps its state (and its scroll) when
    /// the user comes back to it.
    @State private var opened: Set<SettingsSection> = []
    @FocusState private var sidebarFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            List(selection: selection) {
                ForEach(SettingsSection.allCases) { row in
                    Label(row.label.title, systemImage: row.label.icon).tag(row)
                }
            }
            .listStyle(.sidebar)
            // On the card, not a sidebar material of its own.
            .scrollContentBackground(.hidden)
            .focused($sidebarFocused)
            .frame(width: 200)
            // A raised card like the toolbar's capsules, instead of a divider beside the sections.
            .modifier(GlassCard(cornerRadius: 20, raised: true))
            // Level with the form's first section (its -16 margin cancels the grouped inset), close under the title bar.
            .padding(.top, 4)
            .padding([.leading, .bottom], 12)
            ZStack {
                ForEach(SettingsSection.allCases.filter(opened.contains)) { page in
                    let selected = page == navigation.section
                    content(page)
                        .formStyle(.grouped)
                        .scrollContentBackground(.hidden)
                        // Negative: cancels most of the grouped form's own top inset, so its first section starts
                        // level with the sidebar card.
                        .contentMargins(.top, -16, for: .scrollContent)
                        .opacity(selected ? 1 : 0)
                        // The leaving section fades out faster, so the two never show through each other.
                        .animation(switchAnimation(selected: selected), value: selected)
                        .allowsHitTesting(selected)
                        .disabled(!selected)
                        .accessibilityHidden(!selected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { sidebarFocused = true }
        .onChange(of: navigation.section, initial: true) { _, new in opened.insert(new) }
        .onChange(of: appearance) { _, mode in mode.apply() }
    }

    /// Ignores deselection (a click in the empty sidebar): a section is always shown.
    private var selection: Binding<SettingsSection?> {
        Binding(get: { navigation.section }, set: { if let new = $0 { navigation.section = new } })
    }

    /// A fade between sections; an instant switch under Reduce Motion.
    private func switchAnimation(selected: Bool) -> Animation? {
        if reduceMotion { return nil }
        return selected ? Motion.standard : Motion.exit
    }

    @ViewBuilder
    private func content(_ section: SettingsSection) -> some View {
        switch section {
        case .general:
            Form {
                Section {
                    LabeledContent("Theme") {
                        CapsuleTabs(selection: $appearance, tabs: AppearanceMode.allCases,
                                    title: { Text($0.title) }, compact: true)
                            .fixedSize()
                    }
                    LaunchAtLoginRow()
                }
            }
        case .permissions:
            PermissionsSection()
        case .about:
            AboutSection()
        }
    }
}

/// Launch at login through `SMAppService.mainApp`, with a `CompactSwitch` (which draws no label of its own). The
/// switch follows the login item's real status, which can also change in System Settings > General > Login Items.
private struct LaunchAtLoginRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var note: String?

    var body: some View {
        LabeledContent {
            Toggle("Launch at login", isOn: isOn)
                .toggleStyle(CompactSwitch())
                .labelsHidden()
        } label: {
            Text("Launch at login")
            if let hint = note ?? approvalHint { Text(hint) }
        }
        .onAppear(perform: sync)
        // The section stays alive once opened: catch a change made in System Settings when the app comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in sync() }
    }

    private var isOn: Binding<Bool> {
        Binding(get: { status == .enabled || status == .requiresApproval }, set: { set($0) })
    }

    private var approvalHint: String? {
        status == .requiresApproval ? "Approve SimpleMenu in System Settings > General > Login Items." : nil
    }

    private func set(_ enabled: Bool) {
        note = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            note = error.localizedDescription
        }
        sync()
    }

    private func sync() {
        status = SMAppService.mainApp.status
    }
}

/// The Accessibility status, why SimpleMenu needs it, and the buttons that ask for it.
private struct PermissionsSection: View {
    @Environment(AccessibilityPermission.self) private var accessibility: AccessibilityPermission?

    var body: some View {
        let trusted = accessibility?.isTrusted == true
        Form {
            Section {
                LabeledContent {
                    Label(trusted ? "Granted" : "Not granted",
                          systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                } label: {
                    Text("Accessibility")
                    Text("SimpleMenu reads the menu bar items through Accessibility to list them and to open them. "
                        + "It never needs Screen Recording.")
                }
                LabeledContent("System Settings") {
                    HStack(spacing: 8) {
                        Button("Request Access") { accessibility?.request() }
                            .disabled(trusted)
                        Button("Open System Settings") { accessibility?.openSystemSettings() }
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                }
            }
        }
    }
}

/// The app's name and version from the bundle.
private struct AboutSection: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSImage(named: "logo_bg") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(AppInfo.name).font(.title2.weight(.semibold))
            Text("Version \(AppInfo.version)")
                .foregroundStyle(.secondary)
            Text("Hides menu bar items with a private macOS API, which a system update may change.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The app's name and version from the bundle (About section and the window's header row).
enum AppInfo {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "SimpleMenu"
    }

    /// "0.1.0".
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// "0.1.0 (1)".
    static var version: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(shortVersion) (\($0))" } ?? shortVersion
    }
}
