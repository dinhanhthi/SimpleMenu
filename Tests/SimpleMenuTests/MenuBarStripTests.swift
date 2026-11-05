import CoreGraphics
import Testing

// `isInMenuBarStrip` lives in Layout.swift, which is compiled into this hostless bundle.

/// A 1920 pt display's menu bar (24 pt), with the 1 pt above and 2 pt below slack `menuBarStrips()` adds.
private let strips = [CGRect(x: 0, y: -1, width: 1920, height: 27)]

@Suite struct MenuBarStripTests {
    @Test func inBarFramePasses() {
        #expect(isInMenuBarStrip(CGRect(x: 1500, y: 0, width: 30, height: 24), strips: strips))
    }

    @Test(arguments: [
        CGRect(x: 1500, y: 400, width: 30, height: 24),  // below the menu bar, e.g. over a dialog
        CGRect(x: 1000, y: 0, width: 500, height: 24),  // wider than 400 pt
    ])
    func offBarOrOverWideFrameFails(_ frame: CGRect) {
        #expect(!isInMenuBarStrip(frame, strips: strips))
    }
}
