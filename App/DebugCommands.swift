// DEBUG only: lets an agent drive the hiding engine from Bash (`Spike post <cmd>`), absent from Release.
#if DEBUG
import Foundation
import os

/// Observes the distributed notification `com.math2it.simplemenu.debug` and runs its `userInfo["cmd"]` through
/// the same controller methods as the UI. Commands:
/// - `peek`: same as a left click on SimpleMenu, so it toggles (a second `peek` during a peek collapses)
/// - `collapse`
/// - `setSection <bundleID> <visible|hidden|alwaysHidden>`
/// - `open <bundleID> <index>`: same as a dropdown row click on that item
/// - `dropdown`: same as an Option-click on SimpleMenu, so it toggles (a second `dropdown` closes it)
@MainActor
final class DebugCommands: NSObject {
    static let notificationName = Notification.Name("com.math2it.simplemenu.debug")
    private nonisolated static let logger = Logger(subsystem: "com.math2it.simplemenu", category: "debug")

    private let controller: MenuBarController

    init(controller: MenuBarController) {
        self.controller = controller
        super.init()
        // `.deliverImmediately`: an inactive LSUIElement app would otherwise never get it.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: Self.notificationName, object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    /// Reads the command off the (non-Sendable) notification at once, then runs it on the main actor.
    @objc private nonisolated func received(_ notification: Notification) {
        let cmd = notification.userInfo?["cmd"] as? String ?? ""
        Self.logger.notice("received cmd=\"\(cmd, privacy: .public)\"")
        Task { @MainActor in self.run(cmd) }
    }

    private func run(_ cmd: String) {
        let words = cmd.split(separator: " ").map(String.init)
        switch words.first {
        case "peek":
            controller.togglePeek()
        case "collapse":
            controller.collapse()
        case "setSection":
            guard words.count == 3, let section = BarSection(rawValue: words[2]) else {
                Self.logger.notice("usage: setSection <bundleID> <visible|hidden|alwaysHidden>")
                return
            }
            controller.setSection(section, for: words[1])
        case "dropdown":
            controller.toggleDropdown()
        case "open":
            guard words.count == 3, let index = Int(words[2]), index >= 0 else {
                Self.logger.notice("usage: open <bundleID> <index>")
                return
            }
            controller.open(bundleID: words[1], index: index)
        default:
            Self.logger.notice("unknown cmd=\"\(cmd, privacy: .public)\"")
            return
        }
        let mode = String(describing: controller.mode)
        Self.logger.notice("done cmd=\"\(cmd, privacy: .public)\" mode=\(mode, privacy: .public)")
    }
}
#endif
