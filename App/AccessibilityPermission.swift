// Accessibility (AX) trust state, adapted from FastMoji's AccessibilityPermission.
import AppKit
import ApplicationServices
import Observation
import os

/// Accessibility (AX) trust state. Reading it never prompts; only `request()` does, and that must only be called
/// from a user action. Created untrusted, it polls until trusted (an accessory app rarely becomes active), so a
/// grant made while the app runs is picked up without a relaunch.
@MainActor
@Observable
final class AccessibilityPermission {
    private(set) var isTrusted: Bool

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    private static let logger = Logger(subsystem: "com.math2it.simplemenu", category: "permissions")
    private static let settingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    init() {
        isTrusted = AXIsProcessTrusted()
        Self.log(isTrusted)
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if !isTrusted { startPolling() }
    }

    /// Shows the system prompt and opens System Settings > Privacy > Accessibility.
    func request() {
        // The value of `kAXTrustedCheckOptionPrompt`, a global var Swift 6 rejects as not concurrency-safe.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        update(AXIsProcessTrustedWithOptions(options))
        openSystemSettings()
        if !isTrusted { startPolling() }
    }

    /// Opens System Settings > Privacy & Security > Accessibility.
    func openSystemSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    private func refresh() {
        update(AXIsProcessTrusted())
        if isTrusted { stopPolling() }
    }

    private func update(_ trusted: Bool) {
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        Self.log(trusted)
    }

    private static func log(_ trusted: Bool) {
        logger.notice("accessibility trusted=\(trusted, privacy: .public)")
    }

    private func startPolling() {
        guard timer == nil else { return }
        // The AppDelegate keeps the instance for the app lifetime; `refresh()` stops the timer once trusted.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
