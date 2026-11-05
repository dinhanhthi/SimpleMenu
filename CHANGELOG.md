# Changelog

All notable changes to SimpleMenu are listed here. `scripts/publish-release.sh` uses the `## [X.Y.Z]` section of the version being released as the GitHub Release notes.

## [Unreleased]

- Hide menu bar items per app in three sections: Visible, Hidden and Always hidden. System items always stay.
- Peek: a click on the SimpleMenu logo shows the Hidden apps in the menu bar until "Re-hide after" (default 5 s) or a click elsewhere.
- Dropdown: an Option-click lists the Hidden and Always hidden apps, and a row opens that item's real menu.
- Drag-and-drop layout in Settings > Menu Bar Layout, applied at once, and a setting for where new apps go (default Visible).
- Optional global hotkeys for Peek and Dropdown, with no defaults.
- Optional last-seen snapshots of hidden items in the dropdown (needs Screen Recording).
- Optional on-device Apple Intelligence suggestions for the layout, applied only when you accept them.
- Hiding turns itself off, with the reason in Settings > Permissions, when the private menu bar API is unavailable or SimpleMenu does not run from /Applications.
- Updates through Sparkle: "Check for Updates…" in the logo menu and the app menu, plus scheduled checks.

## [0.1.0] - YYYY-MM-DD

- First version.
