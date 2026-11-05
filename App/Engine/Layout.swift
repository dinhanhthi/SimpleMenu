import Foundation

// Pure layout model, allow-list computation and the menu bar strip check (Foundation only).
// Compiled into the app and directly into the hostless test bundle.

enum BarSection: String, Codable, CaseIterable, Sendable {
    case visible, hidden, alwaysHidden
}

/// Bundle ID -> section. Encodes as the flat JSON object {"<bundleID>":"hidden"}.
/// A missing entry counts as visible. System items are never in the layout.
struct Layout: Codable, Equatable, Sendable {
    var sections: [String: BarSection]

    init(sections: [String: BarSection] = [:]) {
        self.sections = sections
    }

    init(from decoder: any Decoder) throws {
        sections = try decoder.singleValueContainer().decode([String: BarSection].self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(sections)
    }
}

enum BarMode: Equatable, Sendable {
    case collapsed, peek, open(String)
}

/// Persists the layout as a JSON string in UserDefaults key `Layout`.
struct LayoutStore {
    static let key = "Layout"

    var defaults: UserDefaults = .standard

    /// Missing or unreadable data loads as an empty layout, which hides nothing.
    func load() -> Layout {
        guard let json = defaults.string(forKey: Self.key),
              let layout = try? JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        else { return Layout() }
        return layout
    }

    func save(_ layout: Layout) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(layout) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }
}

/// Bundle IDs not yet in the layout get `default`; existing entries are kept.
func assignNewApps(seen: [String], layout: Layout, default section: BarSection) -> Layout {
    var result = layout
    for id in seen where result.sections[id] == nil {
        result.sections[id] = section
    }
    return result
}

/// Bundle IDs allowed in the menu bar for `mode`, sorted and de-duplicated.
/// collapsed = running - hidden - alwaysHidden + selfID
/// peek      = running - alwaysHidden + selfID
/// open(b)   = collapsed + b
func allowedBundleIDs(running: [String], layout: Layout, mode: BarMode, selfID: String) -> [String] {
    var allowed = Set<String>([selfID])
    for id in running {
        switch (layout.sections[id] ?? .visible, mode) {
        case (.visible, _), (.hidden, .peek):
            allowed.insert(id)
        case (.hidden, _), (.alwaysHidden, _):
            break
        }
    }
    if case .open(let id) = mode {
        allowed.insert(id)
    }
    return allowed.sorted()
}

/// True when `frame` (top-left global, like AX frames) is non-empty, at most `maxWidth` wide and inside one of
/// `strips` (each display's menu bar, top-left global, tolerances included). AX frames are the owning app's own
/// report, so a synthetic click is posted only on a frame that passes. No strips: false.
func isInMenuBarStrip(_ frame: CGRect, strips: [CGRect], maxWidth: CGFloat = 400) -> Bool {
    guard frame.width > 0, frame.height > 0, frame.width <= maxWidth else { return false }
    return strips.contains { strip in
        frame.minX >= strip.minX && frame.maxX <= strip.maxX && frame.minY >= strip.minY && frame.maxY <= strip.maxY
    }
}
