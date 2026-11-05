import Foundation
import Testing

// Layout.swift is compiled into this hostless bundle, so its types are used directly.

private let selfID = "com.math2it.simplemenu"

private let layout = Layout(sections: [
    "com.example.visible": .visible,
    "com.example.hidden": .hidden,
    "com.example.always": .alwaysHidden,
])

private let running = ["com.example.visible", "com.example.hidden", "com.example.always", "com.example.new"]

@Suite struct AllowListTests {
    @Test func collapsedHidesHiddenAndAlwaysHiddenButKeepsSelfAndUnassigned() {
        let allowed = allowedBundleIDs(running: running, layout: layout, mode: .collapsed, selfID: selfID)
        #expect(allowed == [selfID, "com.example.new", "com.example.visible"].sorted())
    }

    @Test func peekNeverRevealsAlwaysHidden() {
        let allowed = allowedBundleIDs(running: running, layout: layout, mode: .peek, selfID: selfID)
        #expect(allowed.contains("com.example.hidden"))
        #expect(!allowed.contains("com.example.always"))
    }

    @Test(arguments: ["com.example.hidden", "com.example.always"])
    func openRevealsTheOpenedApp(_ id: String) {
        let allowed = allowedBundleIDs(running: running, layout: layout, mode: .open(id), selfID: selfID)
        #expect(allowed.contains(id))
    }
}

@Suite struct PersistenceTests {
    /// Runs `body` with a throwaway UserDefaults suite and removes it afterwards.
    private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "SimpleMenuTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func layoutSurvivesSaveAndLoad() {
        withSuite { defaults in
            let store = LayoutStore(defaults: defaults)
            store.save(layout)
            #expect(store.load() == layout)
        }
    }

    @Test func flatJSONLoadsToSection() {
        withSuite { defaults in
            defaults.set(#"{"com.example.a":"hidden"}"#, forKey: LayoutStore.key)
            #expect(LayoutStore(defaults: defaults).load().sections == ["com.example.a": .hidden])
        }
    }

    @Test func corruptDataLoadsAsEmptyLayoutThatHidesNothing() {
        withSuite { defaults in
            defaults.set(#"{"sections":"#, forKey: LayoutStore.key)
            let loaded = LayoutStore(defaults: defaults).load()
            #expect(loaded == Layout())
            let allowed = allowedBundleIDs(running: running, layout: loaded, mode: .collapsed, selfID: selfID)
            #expect(allowed == (running + [selfID]).sorted())
        }
    }

    @Test func assignNewAppsGivesOnlyUnseenAppsTheDefault() {
        let result = assignNewApps(seen: ["com.example.visible", "com.example.new"], layout: layout, default: .hidden)
        #expect(result.sections["com.example.new"] == .hidden)
        #expect(result.sections["com.example.visible"] == .visible)
        #expect(result.sections.count == layout.sections.count + 1)
    }
}
