<div align="center">

<img src="assets/logo_bg.png" width="128" alt="SimpleMenu icon">

# SimpleMenu

**Hide the menu bar items you don't need, and get them back with a click.**

</div>

I really dislike how long the menu bar items on macOS can get, and how often they end up missing or overflowing. SimpleMenu is a small menu bar app for macOS 27 that keeps the bar short.

## Features

- Three sections per app: **Visible**, **Hidden** and **Always hidden**. System items (Clock, Wi-Fi, Battery, Control Center, ...) always stay.
- A click on the SimpleMenu logo peeks: the Hidden apps show in the real menu bar, with live values, and hide again after a delay or, unless turned off, a click elsewhere.
- Option-click (or a hotkey) opens a bar of icons under the menu bar, or a dropdown list, with the Hidden and Always hidden apps. An icon or a row opens that item's real menu.
- Drag-and-drop layout in Settings > Layout, applied at once.
- Optional global hotkeys for Peek and Dropdown.
- Optional on-device Apple Intelligence suggestions for the layout, which you accept one by one.

## Requirements

- macOS 27 only.
- **Run it from `/Applications`.** Run from anywhere else, macOS 27 also hides SimpleMenu's own icon, so SimpleMenu keeps hiding off and Settings > Permissions says why.

## Permissions

- **Accessibility** (required): SimpleMenu reads the menu bar items through Accessibility to list them, and posts the one click that opens an item from the bar or the dropdown.
- **Apple Intelligence** (optional, off by default): "Suggest with Apple Intelligence" in Settings > AI runs the on-device model only, and only when you click "Suggest". Nothing leaves the Mac, and a suggestion never applies on its own: you click Accept.

## Private API

SimpleMenu hides items with a private macOS menu bar restriction (the assessment mode of `MenuBarClientCore`), resolved at runtime. A macOS update may change or remove it. SimpleMenu then turns hiding off, leaves the full menu bar shown, and says why in Settings > Permissions. Quitting SimpleMenu always brings every item back.

## Usage

- **Peek:** click the logo. The Hidden apps show until "Re-hide after" (Settings > General: 3, 5, 10 or 20 s, default 5), a click elsewhere (unless "Hide on outside click" is off in Settings > General), or another click on the logo. Click a peeked item to use it as usual; the bar re-hides once its menu closes. Always hidden apps do not show in a peek.
- **Bar or dropdown:** Option-click the logo. It shows the running Hidden apps, then the Always hidden ones; click one to open that item. "Option-click opens" (Settings > General) picks the style: **Bar** (default) is a row of app icons under the menu bar, one per item, with the name on hover; **Dropdown** is a list with each item's text.
- **Menu:** right-click or Control-click the logo for "Settings…", "Check for Updates…" and "Quit SimpleMenu".
- **Layout:** Settings > Layout has one column per section. Drag an app between the columns. Hiding is per app: all of an app's items move together.
- **New apps:** the first time SimpleMenu sees an app's menu bar items, the app goes to "New apps go to" (Settings > General, default Visible).
- **Hotkeys:** record "Peek" and "Dropdown" (opens the bar or the dropdown, per "Option-click opens") in Settings > General. They have no defaults, so they never clash with another app's shortcuts.

## Known limitations

- A peek can push items under the notch on a MacBook with a notch.
- While collapsed, a newly launched app is hidden for a moment, until SimpleMenu re-applies the layout (about 0.3 s).
- Items of a process without a bundle ID were not hidden in testing: they count under the app responsible for them.
- Opening an item from the bar or the dropdown moves the pointer to it for the click, then puts it back.
- The logo shows no highlight during a peek on macOS 27.
- Apple Intelligence suggestions need a Mac that supports Apple Intelligence, with it turned on.
- Hiding works only from `/Applications/` (`~/Applications` is untested).

## Build

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project is generated from `project.yml` and not in git.

```sh
xcodegen generate
xcodebuild -project SimpleMenu.xcodeproj -scheme SimpleMenu -configuration Debug build
xcodebuild -project SimpleMenu.xcodeproj -scheme SimpleMenu -configuration Debug test
```

- Debug is signed with Developer ID (team in `project.yml`), so the Accessibility grant survives rebuilds. Without that certificate, change the signing in `project.yml`.
- A build run from Xcode's DerivedData never hides anything: copy `SimpleMenu.app` to `/Applications` to test hiding.
- The tests are hostless: they never launch SimpleMenu or touch the real menu bar.
