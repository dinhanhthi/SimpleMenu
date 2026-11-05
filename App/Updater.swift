import AppKit
import os
import Sparkle

/// Sparkle updater, started only when `SUPublicEDKey` is a base64 Ed25519 public key (32 bytes); an empty or
/// malformed key would show Sparkle's misconfiguration alert. Until then "Check for Updates…" stays disabled.
@MainActor
final class Updater {
    private(set) var canCheckForUpdates = false

    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                          userDriverDelegate: nil)

    func start() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Data(base64Encoded: key)?.count == 32 else {
            Logger(subsystem: "com.math2it.simplemenu", category: "Updater")
                .notice("Updater off: SUPublicEDKey is not a base64 32-byte EdDSA public key")
            return
        }
        controller.startUpdater()
        canCheckForUpdates = true
    }

    /// Sparkle's check, with its window in front: SimpleMenu is an LSUIElement app.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
