import CoreGraphics
import Foundation
import Observation
import os
import ScreenCaptureKit

/// A last-seen image of one status item. `CGImage` is immutable, so the box carries it across actors for Swift 6
/// (like `AXElementBox`).
struct Snapshot: @unchecked Sendable {
    let image: CGImage
    let date: Date
    /// The item's frame size in points, to draw the image at its real size.
    let pointSize: CGSize
}

/// Opt-in Screen Recording snapshots of status items, for the dropdown ("last seen", never live: on macOS 27 the
/// bar is one composited window). In memory only, keyed by `bundleID#index`.
///
/// Never prompts on its own: `capture(_:)` runs only when `CGPreflightScreenCaptureAccess` says granted.
/// `requestAccess()`, which may prompt, is for the Settings row.
@MainActor
@Observable
final class MenuBarCapture {
    /// UserDefaults key of the opt-in (default off). Settings use `@AppStorage` on it; the engine reads it per capture.
    static let settingKey = "CaptureSnapshots"

    private(set) var snapshots: [String: Snapshot] = [:]

    private nonisolated static let logger = Logger(subsystem: "com.math2it.simplemenu", category: "Capture")

    static func key(bundleID: String, index: Int) -> String { "\(bundleID)#\(index)" }

    /// Whether Screen Recording is granted; never prompts.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks for Screen Recording (may show the system prompt). For the Settings row only, never the capture path.
    /// macOS may only report the grant after a relaunch.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    /// Forgets every cached image (the switch was turned off).
    func clear() { snapshots = [:] }

    /// Captures each item's frame (laid out and fresh: the caller filters) and caches the images. Skips everything
    /// unless access is already granted, checked before any ScreenCaptureKit call so nothing can prompt.
    func capture(_ items: [MenuBarItem]) async {
        guard !items.isEmpty else { return }
        guard Self.isGranted else {
            #if DEBUG
            Self.logger.notice("capture: skipped, Screen Recording not granted")
            #endif
            return
        }
        let start = ContinuousClock.now
        let results = await withTaskGroup(of: (String, Snapshot?).self) { group in
            for item in items {
                let key = Self.key(bundleID: item.bundleID, index: item.index)
                let frame = item.frame
                group.addTask { (key, await Self.capture(frame)) }
            }
            var results: [(String, Snapshot?)] = []
            for await result in group { results.append(result) }
            return results
        }
        var captured = 0
        for case let (key, snapshot?) in results {
            snapshots[key] = snapshot
            captured += 1
        }
        #if DEBUG
        let elapsed = ContinuousClock.now - start
        Self.logger.notice("""
            capture: \(captured, privacy: .public) of \(items.count, privacy: .public) items in \
            \(elapsed, privacy: .public)
            """)
        #else
        _ = (start, captured)
        #endif
    }

    /// One image of `frame`, or nil on error. AX frames are top-left global points, and `captureImage(in:)` takes a
    /// rect in points in the same CG display space (top-left origin of the primary display, display agnostic), so
    /// the frame is passed as is, with no flip.
    private nonisolated static func capture(_ frame: CGRect) async -> Snapshot? {
        await withCheckedContinuation { continuation in
            SCScreenshotManager.captureImage(in: frame) { image, error in
                if let error {
                    logger.error("""
                        capture: \(String(describing: frame), privacy: .public) failed: \(error, privacy: .public)
                        """)
                }
                continuation.resume(returning: image.map { Snapshot(image: $0, date: Date(), pointSize: frame.size) })
            }
        }
    }
}
