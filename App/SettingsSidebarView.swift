// The Settings page, sidebar layout: the sections in a raised card, the selected one's form on the right over the
// window's glass; each change is saved at once.
import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// The Settings page `MainView` shows; the tab layout defines the same name.
typealias SettingsRoot = SettingsSidebarView

/// A sidebar section. Adding one: a case, its row in `label`, its form in `SettingsSidebarView.content`.
enum SettingsSection: CaseIterable, Identifiable {
    case layout, general, permissions, ai, about

    var id: Self { self }

    var label: (title: String, icon: String) {
        switch self {
        case .layout: ("Layout", "menubar.rectangle")
        case .general: ("General", "gearshape")
        case .permissions: ("Permissions", "hand.raised")
        case .ai: ("AI", "sparkles")
        case .about: ("About", "info.circle")
        }
    }
}

struct SettingsSidebarView: View {
    /// The selected section, shared with the AppDelegate so a menu can open a section.
    @Bindable var navigation: Navigation
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.defaultMode
    /// Read by `MenuBarController` at the next peek; the default matches its fallback.
    @AppStorage(MenuBarController.rehideDelayKey) private var rehideDelay: Double = 5
    /// Read by `MenuBarController` on every click in a peek; the default matches its fallback.
    @AppStorage(MenuBarController.collapseOnOutsideClickKey) private var collapseOnOutsideClick = true
    /// Read by `MenuBarController` at the next scan; the default matches its fallback.
    @AppStorage(MenuBarController.newAppSectionKey) private var newAppSection: BarSection = .visible
    /// Read by `MenuBarController` on every Option-click or Dropdown hotkey; the default matches its fallback.
    @AppStorage(MenuBarController.optionClickPanelKey) private var optionClickPanel: DropdownStyle = .bar
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
            .frame(width: 150)
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
                        // level with the sidebar card. The layout is no form: it pads itself.
                        .contentMargins(.top, page == .layout ? 0 : -16, for: .scrollContent)
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
        case .layout:
            LayoutSettingsView()
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
                Section {
                    LabeledContent {
                        CapsuleTabs(selection: $rehideDelay, tabs: [3, 5, 10, 20],
                                    title: { Text("\(Int($0)) s") }, compact: true)
                            .fixedSize()
                    } label: {
                        Text("Re-hide after")
                        Text("How long a click on SimpleMenu shows the hidden items.")
                    }
                    LabeledContent {
                        Toggle("Hide on outside click", isOn: $collapseOnOutsideClick)
                            .toggleStyle(CompactSwitch())
                            .labelsHidden()
                    } label: {
                        Text("Hide on outside click")
                        Text("A click elsewhere hides the items again. Off, they stay until \"Re-hide after\" or "
                            + "another click on SimpleMenu.")
                    }
                    LabeledContent {
                        CapsuleTabs(selection: $newAppSection, tabs: BarSection.allCases,
                                    title: { Text($0.title) }, compact: true)
                            .fixedSize()
                    } label: {
                        Text("New apps go to")
                        Text("Where an app's menu bar items go the first time SimpleMenu sees them.")
                    }
                    LabeledContent {
                        CapsuleTabs(selection: $optionClickPanel, tabs: DropdownStyle.allCases,
                                    title: { Text($0.title) }, compact: true)
                            .fixedSize()
                    } label: {
                        Text("Option-click opens")
                        Text("What an Option-click on SimpleMenu and the Dropdown hotkey open: a row of icons under "
                            + "the menu bar, or a list.")
                    }
                }
                Section {
                    KeyboardShortcuts.Recorder(for: .peek) {
                        Text("Peek")
                        Text("Same as a click on SimpleMenu: shows the hidden items, or hides them again.")
                    }
                    KeyboardShortcuts.Recorder(for: .dropdown) {
                        Text("Dropdown")
                        Text("Same as an Option-click on SimpleMenu: opens the bar or the dropdown.")
                    }
                }
            }
        case .permissions:
            PermissionsSection()
        case .ai:
            AISection()
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
    @Environment(MenuBarController.self) private var menuBar: MenuBarController?

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
                    Text("SimpleMenu reads the menu bar items through Accessibility to list them and to open them.")
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
            if let reason = menuBar?.hidingUnavailableReason {
                Section {
                    LabeledContent {
                        Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } label: {
                        Text("Menu bar hiding")
                        Text("The menu bar stays fully shown. \(reason)")
                    }
                }
            }
        }
    }
}

/// Opt-in on-device suggestions (`AISuggestions`): the switch, the model's availability, and one row per app the
/// model would move, with an Accept button. The model runs only on a click on "Suggest" (it can take a lot of
/// memory), never on opening the section; nothing applies on its own.
private struct AISection: View {
    @Environment(MenuBarController.self) private var menuBar: MenuBarController?
    @AppStorage(AppClassifier.settingKey) private var enabled = false
    /// Not observable (the model's availability is read on demand): re-read on appear, on app activation and
    /// before each run. Reading it does not load the model.
    @State private var unavailableReason: String?
    /// False until `checkAvailability()` first ran, so no "Available" state shows before the check.
    @State private var checked = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Toggle("Suggest with Apple Intelligence", isOn: $enabled)
                        .toggleStyle(CompactSwitch())
                        .labelsHidden()
                } label: {
                    Text("Suggest with Apple Intelligence")
                    Text("The on-device model suggests which apps to hide: items that only show status go to "
                        + "Hidden, items you click stay Visible. Nothing leaves this Mac, and nothing moves until "
                        + "you accept it.")
                }
                if enabled && checked { availabilityRow }
            }
            if enabled, checked, unavailableReason == nil, let menuBar {
                suggestionsSection(menuBar)
            }
        }
        .onChange(of: enabled, initial: true) { checkAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkAvailability()
        }
    }

    @ViewBuilder
    private var availabilityRow: some View {
        if let reason = unavailableReason {
            LabeledContent {
                Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } label: {
                Text("Apple Intelligence")
                Text(reason)
            }
        } else {
            LabeledContent {
                Label("Available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } label: {
                Text("Apple Intelligence")
            }
        }
    }

    @ViewBuilder
    private func suggestionsSection(_ menuBar: MenuBarController) -> some View {
        let classifier = menuBar.classifier
        let pending = pendingSuggestions(menuBar)
        Section("Suggestions") {
            LabeledContent {
                if classifier.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Suggest") { run() }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(menuBar.knownApps.isEmpty)
                }
            } label: {
                Text(classifier.isRunning ? "Asking the on-device model..." : "Ask the model")
                Text("Asks the on-device model about every app SimpleMenu knows. It never runs on its own.")
            }
            ForEach(pending, id: \.bundleID) { row in
                LabeledContent {
                    Button("Accept") {
                        menuBar.setSection(row.suggestion.section, for: row.bundleID)
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .accessibilityLabel("Accept: move \(row.name) to \(row.suggestion.section.title)")
                } label: {
                    HStack(spacing: 8) {
                        if let icon = row.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text("\(row.suggestion.section.title): \(row.suggestion.reason)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // While running, the progress shows in the button's row.
            if !classifier.isRunning {
                if classifier.suggestions.isEmpty {
                    Text(menuBar.knownApps.isEmpty ? "No suggestions yet." : "No suggestions yet. Click Suggest.")
                        .foregroundStyle(.secondary)
                } else if pending.isEmpty {
                    Text("No suggestions: every app is already where the model would put it.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One suggestion row to show.
    private struct PendingSuggestion {
        let bundleID: String
        let name: String
        let icon: NSImage?
        let suggestion: Suggestion
    }

    /// Suggestions whose app is not in the suggested section yet (a missing layout entry counts as visible),
    /// sorted by app name. Always-hidden apps are the user's call and never get one.
    private func pendingSuggestions(_ menuBar: MenuBarController) -> [PendingSuggestion] {
        menuBar.classifier.suggestions
            .filter { id, suggestion in
                let current = menuBar.layout.sections[id] ?? .visible
                return current != .alwaysHidden && current != suggestion.section
            }
            .map { id, suggestion in
                let known = menuBar.knownApps[id]
                return PendingSuggestion(bundleID: id, name: known?.name ?? id, icon: known?.icon,
                                         suggestion: suggestion)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads whether the model can run, without running it.
    private func checkAvailability() {
        guard enabled, let menuBar else { return }
        unavailableReason = menuBar.classifier.unavailableReason
        checked = true
    }

    /// The "Suggest" button: asks the model about every known app again, only while the switch is on and the model
    /// is available. The model runs off the main thread; `suggest` returns at once when a run is in progress.
    private func run() {
        checkAvailability()
        guard enabled, unavailableReason == nil, let menuBar else { return }
        let inputs = AppClassifier.inputs(items: menuBar.items, knownApps: menuBar.knownApps)
        guard !inputs.isEmpty else { return }
        let classifier = menuBar.classifier
        Task { await classifier.suggest(inputs, refresh: true) }
    }
}

extension BarSection {
    /// The section's name in Settings.
    var title: String {
        switch self {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always hidden"
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
