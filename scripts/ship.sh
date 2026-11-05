#!/usr/bin/env bash
#
# ship.sh - End-to-end local release: build -> sign -> notarize -> GitHub Release -> appcast.
#
# Run this AFTER the version-bump commit (scripts/bump-version.sh + CHANGELOG.md) is pushed
# to main. It chains scripts/build-and-notarize.sh, scripts/publish-release.sh and
# scripts/publish-appcast.sh with no interactive prompts. Before building it requires: branch
# main, HEAD == origin/main (only pushed commits ship), a clean tree of tracked files, gh
# authenticated, a non-empty `## [X.Y.Z]` CHANGELOG.md section and no existing tag vX.Y.Z (the
# bump check).
#
# Prereqs (one-time - docs/RELEASING.md section 0, details in each script's header):
#   - "Developer ID Application" cert of team TEAM_ID in the login Keychain
#   - TEAM_ID (default 86H6CNLN4C, or export TEAM_ID=<id>)
#   - notarytool credential profile (default "simplemenu-notary")
#   - Sparkle EdDSA key (generate_keys --account SimpleMenu) + SUPublicEDKey in App/Info.plist
#   - Xcode 27+ selected and xcodegen installed
#   - gh CLI authenticated, origin = github.com/<GH_REPO> (default dinhanhthi/SimpleMenu)
#
# Usage:
#   scripts/ship.sh
#   NOTARY_PROFILE=my-profile scripts/ship.sh
#   ARCHS="arm64 x86_64" GH_REPO=owner/repo scripts/ship.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GH_REPO="${GH_REPO:-dinhanhthi/SimpleMenu}"
export GH_REPO

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] \
  || { echo "error: releases ship from 'main' (you are on '$BRANCH')." >&2; exit 1; }

# Only what is already on origin/main ships: the release commit is pushed before this runs.
git fetch -q origin main || { echo "error: git fetch origin main failed" >&2; exit 1; }
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "error: HEAD ($(git rev-parse --short HEAD)) is not origin/main ($(git rev-parse --short origin/main))." >&2
  echo "       push the release commit (or fast-forward to origin/main), then re-run." >&2
  exit 1
fi

gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated - run 'gh auth login'." >&2; exit 1; }

# Tracked files only: untracked files are ignored.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "error: commit or discard changes to tracked files before building a release" >&2
  exit 1
fi
release_sha="$(git rev-parse HEAD)"

# Version from the committed project.yml (tree is clean, so HEAD == working copy).
VERSION="$(git show HEAD:project.yml \
  | sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9]+\.[0-9]+\.[0-9]+)"?.*/\1/p' \
  | head -1)"
[[ -n "$VERSION" ]] || { echo "error: no MARKETING_VERSION found in project.yml" >&2; exit 1; }

# publish-release.sh needs the release notes: check now, not after a notarization. Same
# extraction as publish-release.sh: the lines between `## [X.Y.Z]` and the next `## ` header.
NOTES_BODY="$(awk -v ver="$VERSION" '
  BEGIN { gsub(/\./, "\\.", ver) }
  capture && /^## / { exit }
  $0 ~ ("^## \\[" ver "\\]") { capture=1; next }
  capture { print }
' CHANGELOG.md 2>/dev/null || true)"
[[ -n "$(printf '%s' "$NOTES_BODY" | tr -d '[:space:]')" ]] \
  || { echo "error: no '## [$VERSION]' section with content in CHANGELOG.md - add the release notes first." >&2; exit 1; }

# Bump check - refuse before building: a re-run must never overwrite release/export/ or spend
# a notarization on a version that is already tagged.
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
   || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists - bump the version (scripts/bump-version.sh), or delete the tag" >&2
  echo "       if that release failed half-way (git push origin :refs/tags/$TAG && git tag -d $TAG)." >&2
  exit 1
fi

ZIP="release/export/SimpleMenu-$VERSION.zip"

echo "========================================"
echo "  Shipping SimpleMenu v$VERSION"
echo "========================================"
echo

# Step 1 - Build, sign, notarize, DMG (Keychain prompt -> Always Allow)
echo "==> Step 1/3: build + notarize"
scripts/build-and-notarize.sh

if [[ "$(git rev-parse HEAD)" != "$release_sha" || -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "error: source changed during build; release was not published" >&2
  exit 1
fi

# Step 2 - Tag + GitHub Release (zip + DMG uploaded)
echo "==> Step 2/3: tag + GitHub Release"
scripts/publish-release.sh --yes "$ZIP"

# Step 3 - Generate + commit + push the appcast
echo "==> Step 3/3: appcast"
scripts/publish-appcast.sh "$ZIP"

echo
echo "========================================"
echo "  SimpleMenu v$VERSION shipped!"
echo "  GitHub : https://github.com/$GH_REPO/releases/tag/v$VERSION"
echo "  Appcast: https://raw.githubusercontent.com/$GH_REPO/main/appcast.xml"
echo "========================================"
