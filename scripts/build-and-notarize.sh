#!/usr/bin/env bash
#
# build-and-notarize.sh - Build -> sign -> notarize -> staple a SimpleMenu release locally.
#
# Releases are built locally only (there is no CI release workflow).
#
# Produces, under release/export/:
#   - SimpleMenu-<version>.zip   notarized + stapled -> Sparkle auto-update asset
#   - SimpleMenu-<version>.dmg   notarized + stapled -> manual-download asset
# Then hand the .zip to scripts/publish-release.sh to tag + create the GitHub Release, and to
# scripts/publish-appcast.sh for the Sparkle appcast (scripts/ship.sh runs the whole chain).
#
# project.yml signs the app target with Manual "Developer ID Application" (Debug too, so the
# Accessibility grant survives rebuilds). This script still passes the signing settings on the
# command line (CODE_SIGN_STYLE/CODE_SIGN_IDENTITY/DEVELOPMENT_TEAM) to pin the team, exports with
# the developer-id method, then re-signs Sparkle's nested helpers with the same identity.
#
# Prereqs (one-time - see docs/RELEASING.md section 0):
#   - "Developer ID Application" cert of team TEAM_ID in the login Keychain
#     (Xcode > Settings > Accounts > Manage Certificates)
#   - TEAM_ID: default 86H6CNLN4C, or export TEAM_ID=<10-char team id>
#   - notarytool credential profile (default "simplemenu-notary"):
#       xcrun notarytool store-credentials simplemenu-notary --apple-id <id> --team-id <TEAM_ID>
#   - Sparkle EdDSA public key pasted into SUPublicEDKey (App/Info.plist):
#       generate_keys --account SimpleMenu
#   - Xcode 27+ selected (the app uses the macOS 27 SDK) and xcodegen (brew install xcodegen)
#
# Notarization talks to Apple, so this needs network - "local" means your machine, not offline.
#
# Usage:
#   scripts/build-and-notarize.sh
#   NOTARY_PROFILE=my-profile scripts/build-and-notarize.sh
#   TEAM_ID=ABCDE12345 scripts/build-and-notarize.sh
#   ARCHS="arm64 x86_64" scripts/build-and-notarize.sh   # universal (default: arm64 only)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="SimpleMenu.xcodeproj"
INFO_PLIST="App/Info.plist"
ARCHIVE="release/SimpleMenu.xcarchive"
EXPORT_DIR="release/export"
EXPORT_OPTIONS="release/ExportOptions.plist"
APP="$EXPORT_DIR/SimpleMenu.app"
MIN_MACOS="27.0"   # SimpleMenu's hard minimum (project.yml) - guarded below
TEAM_ID="${TEAM_ID:-86H6CNLN4C}"
NOTARY_PROFILE="${NOTARY_PROFILE:-simplemenu-notary}"
ARCHS="${ARCHS:-arm64}"
SIGN_ID="Developer ID Application"

# Submit to Apple and FAIL the script on anything other than "Accepted". notarytool exits 0
# even when the status is Invalid, so without this an Invalid result sails on into stapler and
# surfaces as a confusing "Error 65" instead of a clear stop. On failure, print the log command.
notarize() {  # $1 = file to submit (zip or dmg)
  local out sid
  if ! out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"; then
    echo "$out" >&2
    echo "error: notarytool submit failed" >&2
    exit 1
  fi
  echo "$out"
  grep -q "status: Accepted" <<<"$out" && return 0
  sid="$(grep -m1 '  id:' <<<"$out" | awk '{print $2}' || true)"
  echo "error: notarization not Accepted for $1 - pull the log to see which binary failed:" >&2
  echo "       xcrun notarytool log $sid --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
}

# Words of $1 sorted and space-joined, so "x86_64 arm64" and "arm64 x86_64" compare equal.
sorted_words() { tr ' ' '\n' <<<"$1" | grep . | sort | tr '\n' ' ' | sed 's/ $//'; }

# --- 0. Tools & prereqs (all before the slow archive) -----------------------
[[ -n "$TEAM_ID" ]] \
  || { echo "error: TEAM_ID is empty - Developer ID signing needs your Apple team id." >&2
       echo "       export TEAM_ID=<10-char team id> (SimpleMenu's team is 86H6CNLN4C)." >&2
       exit 1; }
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
  || { echo "error: TEAM_ID '$TEAM_ID' is not a 10-character Apple team id" >&2; exit 1; }
[[ "$ARCHS" =~ ^(arm64|x86_64)( (arm64|x86_64))*$ ]] \
  || { echo "error: ARCHS '$ARCHS' must be arm64, x86_64 or \"arm64 x86_64\"" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found" >&2; exit 1; }
command -v xcodegen >/dev/null \
  || { echo "error: xcodegen not found - brew install xcodegen" >&2; exit 1; }
[[ -f project.yml && -f "$INFO_PLIST" ]] \
  || { echo "error: project.yml / $INFO_PLIST not found - run from the SimpleMenu repo" >&2; exit 1; }

# Xcode 27+ is REQUIRED: the app targets macOS 27 and uses its SDK, which older Xcodes
# do not have. Fail loudly instead of deep inside the archive log.
XCODE_VER="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
XCODE_MAJOR="${XCODE_VER%%.*}"
if ! [[ "$XCODE_MAJOR" =~ ^[0-9]+$ ]] || (( XCODE_MAJOR < 27 )); then
  echo "error: Xcode 27+ required to build SimpleMenu (have ${XCODE_VER:-unknown})." >&2
  echo "       sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

# Pin the signing identity to the team: exactly one "Developer ID Application: ... (TEAM_ID)"
# identity, used by its SHA-1 hash for the export and the DMG so codesign never picks another
# team's certificate. Capture first (grep -q in a pipe trips pipefail, see step 3). The same
# cert in two keychains lists twice, hence sort -u on the hash.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGN_HASHES="$(grep -F "\"$SIGN_ID: " <<<"$IDENTITIES" | grep -F "($TEAM_ID)\"" \
  | awk '{print $2}' | sort -u || true)"
SIGN_COUNT="$(grep -c . <<<"$SIGN_HASHES" || true)"
if [[ "$SIGN_COUNT" == 0 ]]; then
  echo "error: no '$SIGN_ID: ... ($TEAM_ID)' identity in the keychain." >&2
  echo "       Create it in Xcode > Settings > Accounts > Manage Certificates." >&2
  exit 1
elif [[ "$SIGN_COUNT" != 1 ]]; then
  echo "error: $SIGN_COUNT '$SIGN_ID: ... ($TEAM_ID)' identities in the keychain - ambiguous." >&2
  echo "       Keep only the current one (security find-identity -v -p codesigning)." >&2
  exit 1
fi
SIGN_HASH="$SIGN_HASHES"

# Sparkle refuses unsigned updates: an empty SUPublicEDKey would ship an app that can never
# verify (and so never install) an update.
ED_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$INFO_PLIST" 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$ED_KEY" ]] \
  || { echo "error: SUPublicEDKey is empty in $INFO_PLIST - Sparkle could never verify an update." >&2
       echo "       Run Sparkle's generate_keys --account SimpleMenu and paste the public key (docs/RELEASING.md section 0)." >&2
       exit 1; }
# Same gate as App/Updater.swift: the key must decode from base64 to exactly 32 bytes (Ed25519),
# or the shipped app keeps its updater off.
[[ "$(printf '%s' "$ED_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] \
  || { echo "error: SUPublicEDKey in $INFO_PLIST is not a base64 32-byte EdDSA public key - the app would keep its updater off." >&2
       echo "       Paste the exact output of generate_keys --account SimpleMenu -p (docs/RELEASING.md section 0)." >&2
       exit 1; }

FEED_URL="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$INFO_PLIST" 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$FEED_URL" == https://* ]] \
  || { echo "error: SUFeedURL in $INFO_PLIST is '${FEED_URL:-unset}', expected an https:// URL." >&2
       echo "       Point it at https://raw.githubusercontent.com/dinhanhthi/SimpleMenu/main/appcast.xml" >&2
       exit 1; }

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "error: notarytool credential profile '$NOTARY_PROFILE' is missing or invalid." >&2
       echo "       Create it: xcrun notarytool store-credentials simplemenu-notary --apple-id <id> --team-id $TEAM_ID" >&2
       echo "       or reuse a profile of the same team: NOTARY_PROFILE=<profile-name> scripts/build-and-notarize.sh" >&2
       exit 1; }

# --- 1. Generate the project and guard its Release settings ----------------
# SimpleMenu.xcodeproj is generated from project.yml (gitignored), so regenerate it first.
xcodegen generate
if ! APP_SETTINGS="$(xcodebuild -project "$PROJECT" -target SimpleMenu -configuration Release -showBuildSettings 2>/dev/null)"; then
  echo "error: xcodebuild -showBuildSettings failed - run it by hand to see why:" >&2
  echo "       xcodebuild -project $PROJECT -target SimpleMenu -configuration Release -showBuildSettings" >&2
  exit 1
fi
APP_MIN_OS="$(sed -n 's/^ *MACOSX_DEPLOYMENT_TARGET = //p' <<<"$APP_SETTINGS" | head -1)"
APP_ENTITLEMENTS="$(sed -n 's/^ *CODE_SIGN_ENTITLEMENTS = //p' <<<"$APP_SETTINGS" | head -1)"
VERSION="$(sed -n 's/^ *MARKETING_VERSION = //p' <<<"$APP_SETTINGS" | head -1)"
[[ "$APP_MIN_OS" == "$MIN_MACOS" ]] \
  || { echo "error: SimpleMenu Release MACOSX_DEPLOYMENT_TARGET is '${APP_MIN_OS:-unset}', expected '$MIN_MACOS' (fix project.yml)." >&2; exit 1; }
# No entitlements file by default (no sandbox); if one is added, it must exist and be Release-safe.
if [[ -n "$APP_ENTITLEMENTS" ]]; then
  [[ -f "$APP_ENTITLEMENTS" ]] \
    || { echo "error: SimpleMenu Release CODE_SIGN_ENTITLEMENTS '$APP_ENTITLEMENTS' not found (fix project.yml)." >&2; exit 1; }
  if grep -q "get-task-allow" "$APP_ENTITLEMENTS"; then
    echo "error: $APP_ENTITLEMENTS carries get-task-allow (Debug entitlement) - instant notarization reject" >&2; exit 1
  fi
fi
[[ -n "$VERSION" ]] || { echo "error: no MARKETING_VERSION in the Release build settings" >&2; exit 1; }

echo "==> Building SimpleMenu $VERSION ($ARCHS, team $TEAM_ID, notary profile: $NOTARY_PROFILE)"

# --- 2. Archive (Developer ID) ---------------------------------------------
# Default DerivedData (no -derivedDataPath), so Xcode reuses it (and publish-appcast.sh finds
# Sparkle's generate_appcast there). The signing overrides and ARCHS go on the command line, so
# they apply to every target, the SPM packages (Sparkle, KeyboardShortcuts) included.
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$EXPORT_OPTIONS"
xcodebuild -project "$PROJECT" -scheme SimpleMenu \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  ARCHS="$ARCHS" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  archive

# --- 3. Export with Developer ID -------------------------------------------
# -exportArchive re-signs the app (and any nested code) with Developer ID + a secure timestamp.
mkdir -p "$EXPORT_DIR"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$SIGN_HASH</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR"
[[ -d "$APP" ]] || { echo "error: export did not produce $APP" >&2; exit 1; }

# --- 3b. Re-sign Sparkle's nested helpers with Developer ID + secure timestamp ----
# Sparkle's deeply nested code (Updater.app, Autoupdate, the two XPC services) can stay
# ADHOC-signed with no secure timestamp, and notarization rejects exactly those 4. Sign
# inside-out (nested code first -> framework -> outer app; touching nested code breaks every
# seal above it). --preserve-metadata=entitlements keeps each helper's entitlements while adding
# Developer ID + secure timestamp + hardened runtime. Resolve the version letter (Current -> e.g.
# B) so a future Sparkle bump that changes it does not silently skip these paths; stop if it
# cannot be read. Layout verified for Sparkle 2.10.1 (the pin in project.yml). The sanity gate
# below then checks the final seal.
SPK="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPK" ]] || { echo "error: Sparkle.framework missing from the app - it could never update" >&2; exit 1; }
SPK_CURRENT="$(readlink "$SPK/Versions/Current" 2>/dev/null)" && [[ -n "$SPK_CURRENT" && -d "$SPK/Versions/$SPK_CURRENT" ]] \
  || { echo "error: cannot resolve $SPK/Versions/Current - the Sparkle framework layout changed" >&2; exit 1; }
SPKV="$SPK/Versions/$SPK_CURRENT"
resign() { codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
  --sign "$SIGN_HASH" "$1"; }
resign "$SPKV/XPCServices/Downloader.xpc"
resign "$SPKV/XPCServices/Installer.xpc"
resign "$SPKV/Updater.app"
resign "$SPKV/Autoupdate"
resign "$SPK"        # re-seal the framework over the re-signed helpers
resign "$APP"        # re-seal the outer app over the re-signed framework
echo "==> Re-signed Sparkle nested helpers (Developer ID + timestamp)"

# Sanity-gate the exported app before the (slow) notarization round-trip. Capture codesign
# output into a var first: piping `codesign | grep -q` trips `set -o pipefail` - grep -q exits
# on first match, SIGPIPEs codesign (exit 141), and the pipeline is wrongly seen as failed.
BIN="$APP/Contents/MacOS/SimpleMenu"
BUILT_ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
[[ "$(sorted_words "$BUILT_ARCHS")" == "$(sorted_words "$ARCHS")" ]] \
  || { echo "error: app binary architectures are '${BUILT_ARCHS:-unknown}', expected '$ARCHS'" >&2; exit 1; }
SIGN_INFO="$(codesign -dvvv "$APP" 2>&1)"
# SIGN_ID has no regex metacharacters and TEAM_ID is checked to be [A-Z0-9]{10} above.
grep -qE "^Authority=$SIGN_ID: .*\($TEAM_ID\)$" <<<"$SIGN_INFO" \
  || { echo "error: exported app is not Developer ID signed by team $TEAM_ID" >&2; exit 1; }
grep -qx "TeamIdentifier=$TEAM_ID" <<<"$SIGN_INFO" \
  || { echo "error: exported app is not signed with team $TEAM_ID" >&2; exit 1; }
grep -q "flags=.*runtime" <<<"$SIGN_INFO" \
  || { echo "error: exported app lacks the hardened runtime - notarization will reject it" >&2; exit 1; }
codesign --verify --deep --strict "$APP" \
  || { echo "error: deep signature verification failed on the exported app" >&2; exit 1; }
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
if grep -q "get-task-allow" <<<"$ENTITLEMENTS"; then
  echo "error: app carries get-task-allow (Debug entitlement) - instant notarization reject" >&2; exit 1
fi
# minos guard: the Info.plist minimum and the minos of every slice must both be MIN_MACOS.
BUILT_MIN_OS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$BUILT_MIN_OS" == "$MIN_MACOS" ]] \
  || { echo "error: built app LSMinimumSystemVersion is '${BUILT_MIN_OS:-unset}', expected '$MIN_MACOS'" >&2; exit 1; }
BUILT_MINOS="$(vtool -show-build "$BIN" 2>/dev/null | awk '/minos/ {print $2}' | sort -u || true)"
[[ "$BUILT_MINOS" == "$MIN_MACOS" ]] \
  || { echo "error: app binary minos is '${BUILT_MINOS:-unknown}', expected '$MIN_MACOS'" >&2; exit 1; }
BUILT_ED_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$BUILT_ED_KEY" ]] \
  || { echo "error: built app has an empty SUPublicEDKey - the Info.plist merge dropped it" >&2; exit 1; }
echo "==> Exported Developer-ID-signed $ARCHS app (minos $MIN_MACOS)"

# --- 4. Notarize + staple the app, then ship-zip it ------------------------
# The first zip is a THROWAWAY upload for notarytool; the file we ship is the re-zip AFTER
# stapling (the staple writes the ticket into the .app, not the zip).
( cd "$EXPORT_DIR" && ditto -c -k --keepParent SimpleMenu.app "SimpleMenu-$VERSION.zip" )
notarize "$EXPORT_DIR/SimpleMenu-$VERSION.zip"
( cd "$EXPORT_DIR" \
  && xcrun stapler staple SimpleMenu.app \
  && rm -f "SimpleMenu-$VERSION.zip" \
  && ditto -c -k --keepParent SimpleMenu.app "SimpleMenu-$VERSION.zip" )
spctl -a -vv -t exec "$APP"
echo "==> Notarized + stapled the app"

# --- 5. Build the notarized DMG (manual-download asset) --------------------
# A raw .zip can break when users extract it with a third-party unarchiver (._* files pollute
# the bundle's code seal -> Gatekeeper warning). A DMG is drag-to-install: Finder copies the
# bundle verbatim, so the seal always survives. Built from the already-stapled app.
( cd "$EXPORT_DIR"
  rm -rf dmg-stage && mkdir dmg-stage
  ditto SimpleMenu.app dmg-stage/SimpleMenu.app
  ln -s /Applications dmg-stage/Applications
  hdiutil create -volname "SimpleMenu" -srcfolder dmg-stage -ov -format UDZO "SimpleMenu-$VERSION.dmg"
  rm -rf dmg-stage
  # A DMG is a container, not an executable: --timestamp, no hardened runtime.
  codesign --force --timestamp --sign "$SIGN_HASH" "SimpleMenu-$VERSION.dmg"
  notarize "SimpleMenu-$VERSION.dmg"
  xcrun stapler staple "SimpleMenu-$VERSION.dmg"
  spctl -a -t open --context context:primary-signature -v "SimpleMenu-$VERSION.dmg"
  xcrun stapler validate "SimpleMenu-$VERSION.dmg" )
echo "==> Notarized + stapled the DMG"

# --- 6. Done ---------------------------------------------------------------
echo
echo "Done. Notarized + stapled artifacts:"
echo "  zip : $EXPORT_DIR/SimpleMenu-$VERSION.zip"
echo "  dmg : $EXPORT_DIR/SimpleMenu-$VERSION.dmg"
echo
echo "Next: scripts/publish-release.sh $EXPORT_DIR/SimpleMenu-$VERSION.zip"
echo "      then scripts/publish-appcast.sh $EXPORT_DIR/SimpleMenu-$VERSION.zip"
