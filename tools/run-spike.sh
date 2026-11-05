#!/bin/bash
# Build (only when the source changed), sign and launch the menu bar spike as its own app,
# so it gets its own Accessibility (TCC) grant instead of inheriting the terminal's.
#
#   tools/run-spike.sh list
#   tools/run-spike.sh hide <bundleID> [seconds] [--system-items empty|nil|<id,...>] [--expand-unrestricted]
#                      [--double | --launch-helpers] [--block-args]
#   (--launch-helpers: target com.math2it.simplemenu.spike.helper; Spike launches the helpers itself)
#   tools/run-spike.sh press <bundleID> [--system-items <id,...>] [--open-hold <seconds>]
#   tools/run-spike.sh post <peek|collapse|setSection <bundleID> <section>>   (drives a DEBUG SimpleMenu)
#   tools/run-spike.sh build   (build and sign only, never launches; e.g. to zip Spike.app for a VM)
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <list|hide|press|post|build> [args]" >&2
  exit 64
fi
CMD="$1"
shift

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/tools/menubar-spike.swift"
OUT_DIR="$REPO_ROOT/build/spike"
APP="$OUT_DIR/Spike.app"
BIN="$APP/Contents/MacOS/Spike"
PLIST="$APP/Contents/Info.plist"
IDENTITY="Developer ID Application: Anh-Thi Dinh (86H6CNLN4C)"
# Status item owners for `hide --launch-helpers`: the same binary run as `helper`, as two bundles
# (the subject and an always-allowed probe) and once bare (no bundle ID). Spike launches them;
# they quit themselves after 60 s.
HELPER_APP="$OUT_DIR/SpikeHelper.app"
HELPER_BIN="$HELPER_APP/Contents/MacOS/SpikeHelper"
PROBE_APP="$OUT_DIR/SpikeProbe.app"
PROBE_BIN="$PROBE_APP/Contents/MacOS/SpikeHelper"
BARE_BIN="$OUT_DIR/SpikeHelperBare"

# 1-3. Rebuild and re-sign only when the binary is missing or older than the source,
# so a running Spike.app is never re-linked or re-signed under itself.
if [ ! -x "$BIN" ] || [ ! -f "$PLIST" ] || [ "$SRC" -nt "$BIN" ] || [ ! -x "$HELPER_BIN" ] || [ ! -x "$PROBE_BIN" ] || [ ! -x "$BARE_BIN" ]; then
  echo "building $APP" >&2
  mkdir -p "$APP/Contents/MacOS"
  TMP_BIN="$OUT_DIR/Spike.tmp.$$"
  swiftc -swift-version 6 -O -target arm64-apple-macosx27.0 \
    -framework AppKit -framework ApplicationServices \
    -o "$TMP_BIN" "$SRC"
  mv -f "$TMP_BIN" "$BIN"

  # Info.plist is sealed by the signature: write it before codesign, never after.
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.math2it.simplemenu.spike</string>
	<key>CFBundleExecutable</key>
	<string>Spike</string>
	<key>CFBundleName</key>
	<string>Spike</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>27.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

  # Stable team + bundle ID keep the Accessibility grant across rebuilds.
  codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP"

  for pair in "$HELPER_APP:helper" "$PROBE_APP:probe"; do
    bundle="${pair%%:*}"
    mkdir -p "$bundle/Contents/MacOS"
    cp -f "$BIN" "$bundle/Contents/MacOS/SpikeHelper"
    sed -e "s/com\.math2it\.simplemenu\.spike</com.math2it.simplemenu.spike.${pair##*:}</" \
        -e 's/<string>Spike</<string>SpikeHelper</g' "$PLIST" > "$bundle/Contents/Info.plist"
    codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$bundle"
  done
  cp -f "$BIN" "$BARE_BIN"
  codesign --force --options runtime --timestamp=none -s "$IDENTITY" -i com.math2it.simplemenu.spike.bare "$BARE_BIN"
fi

if [ "$CMD" = "build" ]; then
  exit 0
fi

# 4. Launch as its own process (cwd is / under open, so the log path is absolute).
LOG="$OUT_DIR/spike-$CMD-$$.log"
rm -f "$LOG"
open -W -n "$APP" --args "$CMD" "$@" --out "$LOG"

# 5. Show the log and return the app's own status (open -W does not propagate it).
if [ ! -f "$LOG" ]; then
  echo "run-spike: no log at $LOG (Spike did not start or did not get --out)" >&2
  exit 1
fi
cat "$LOG"
STATUS="$(sed -n 's/^spike-exit-status: \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -n 1)"
if [ -z "$STATUS" ]; then
  echo "run-spike: no exit status in $LOG (Spike crashed or was killed?)" >&2
  exit 1
fi
exit "$STATUS"
