import KeyboardShortcuts

/// The global shortcuts, recorded in Settings. No defaults, so they never clash with another app's shortcuts.
extension KeyboardShortcuts.Name {
    /// Same as a left click on SimpleMenu: peek, or collapse.
    static let peek = Self("peek")
    /// Same as an Option-click on SimpleMenu: the dropdown.
    static let dropdown = Self("dropdown")
}

/// Binds the shortcuts to the same actions as the status item clicks. The handlers run on the main actor, on key up.
@MainActor
enum Hotkeys {
    static func register(menuBar: MenuBarController) {
        KeyboardShortcuts.onKeyUp(for: .peek) { menuBar.togglePeek() }
        KeyboardShortcuts.onKeyUp(for: .dropdown) { menuBar.toggleDropdown() }
    }
}
