<div align="center">

<img src="assets/logo_bg.png" width="128" alt="SimpleMenu logo">

# SimpleMenu

Hide the menu bar items you don't need, and get them back with a click.

[![Download](https://img.shields.io/badge/Download-macOS-black?style=for-the-badge&logo=apple)](https://github.com/dinhanhthi/SimpleMenu/releases/latest)

</div>

## Features

- Three sections per app: **Visible**, **Hidden** and **Always hidden**. System items (Clock, Wi-Fi, Battery, Control Center, ...) always stay.
- Click the logo to peek: the Hidden apps show in the real menu bar, then hide again.
- Option-click the logo (or a hotkey) to open a bar of icons or a dropdown list with the Hidden and Always hidden apps.
- Drag-and-drop layout in Settings > Layout, applied at once.
- Optional global hotkeys, and optional on-device Apple Intelligence suggestions for the layout.

## Requirements

- macOS 27 only.
- **Run it from `/Applications`**, or SimpleMenu keeps hiding off.
- **Accessibility** (required) to read the menu bar items and open them.
- **Apple Intelligence** (optional, on-device) for layout suggestions.

## Usage

- **Peek:** click the logo. Items re-hide after a delay or a click elsewhere.
- **Bar or dropdown:** Option-click the logo, then click an item to open it. The style is in Settings > General.
- **Menu:** right-click the logo for Settings, updates and Quit.
- **Layout:** drag an app between the columns in Settings > Layout.

Quitting SimpleMenu always brings every item back.

## Known limitations

- Hiding uses a private macOS API. A macOS update may break it: SimpleMenu then turns hiding off and says why in Settings > Permissions.
- A peek can push items under the notch.
- A newly launched app is hidden after about 0.3 s.

## Build

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project SimpleMenu.xcodeproj -scheme SimpleMenu -configuration Debug build
```

A build from DerivedData never hides anything: copy `SimpleMenu.app` to `/Applications` to test hiding.
