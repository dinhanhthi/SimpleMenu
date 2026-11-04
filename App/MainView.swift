// The Settings window: the logo in the toolbar, the Settings sections under it, over the window glass.
import AppKit
import SwiftUI

/// The selected Settings section, owned by the AppDelegate so its menus can open a section before the window exists.
@Observable
@MainActor
final class Navigation {
    var section: SettingsSection = .general
}

struct MainView: View {
    @Bindable var navigation: Navigation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The scaffold keeps one settings layout; both define `SettingsRoot`.
        SettingsRoot(navigation: navigation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WindowGlass().ignoresSafeArea())
            // A band behind the transparent title bar, so scrolled content never shows through it; the same glass as
            // the window, so the title bar and the content still read as one.
            .overlay {
                GeometryReader { proxy in
                    WindowGlass()
                        .frame(height: proxy.safeAreaInsets.top)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(.container, edges: .top)
                }
                .allowsHitTesting(false)
            }
            .modifier(HardTopScrollEdge())
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    // The bare logo (no container), gray on light and white on dark, then the name and version.
                    HStack(spacing: 8) {
                        if let logo = StatusItemController.logoObject(
                            named: colorScheme == .dark ? "logo_object_white" : "logo_object_gray", height: 16)
                        {
                            Image(nsImage: logo).accessibilityHidden(true)
                        }
                        Text(AppInfo.name).font(.headline)
                        Text(AppInfo.shortVersion)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                }
                .hiddenSharedBackground()
            }
    }
}
