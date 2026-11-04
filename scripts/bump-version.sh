#!/usr/bin/env bash
#
# bump-version.sh - Bump SimpleMenu's version for a release.
#
# Edits the two version settings in project.yml (the XcodeGen source of truth; the app uses a
# generated Info.plist, so these build settings are the only place the version lives):
#   MARKETING_VERSION       -> CFBundleShortVersionString (user-facing, the vX.Y.Z tag)
#   CURRENT_PROJECT_VERSION -> CFBundleVersion (build number)
#
# The build number ALWAYS increments by 1, so every release has a strictly higher build.
#
# Prereqs: perl (ships with macOS).
#
# Usage:
#   scripts/bump-version.sh 1.1.0     # set marketing version 1.1.0, build +1
#   scripts/bump-version.sh           # keep marketing version, build +1 only
#   PROJECT_YML=/tmp/p.yml scripts/bump-version.sh 1.0.1   # edit another file (tests)
#
# Review the diff and commit the bump yourself.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="${PROJECT_YML:-$REPO_ROOT/project.yml}"
NEW_MARKETING="${1:-}"

[[ -f "$PROJECT_YML" ]] || { echo "error: $PROJECT_YML not found" >&2; exit 1; }

if [[ -n "$NEW_MARKETING" && ! "$NEW_MARKETING" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: marketing version must look like 1.2.3 (got \"$NEW_MARKETING\")" >&2
  exit 1
fi

CURRENT_BUILD="$(grep -Eo 'CURRENT_PROJECT_VERSION: *"?[0-9]+' "$PROJECT_YML" | grep -Eo '[0-9]+$' | head -1 || true)"
[[ -n "$CURRENT_BUILD" ]] || { echo "error: no CURRENT_PROJECT_VERSION found in $PROJECT_YML" >&2; exit 1; }
NEXT_BUILD=$((CURRENT_BUILD + 1))

perl -i -pe "s/(CURRENT_PROJECT_VERSION: *)\"?[0-9]+\"?/\${1}${NEXT_BUILD}/" "$PROJECT_YML"
if [[ -n "$NEW_MARKETING" ]]; then
  perl -i -pe "s/(MARKETING_VERSION: *)\"?[0-9.]+\"?/\${1}${NEW_MARKETING}/" "$PROJECT_YML"
fi

echo "==> Build number (CFBundleVersion):  ${CURRENT_BUILD} -> ${NEXT_BUILD}"
if [[ -n "$NEW_MARKETING" ]]; then
  echo "==> Marketing version:               set to ${NEW_MARKETING}"
else
  echo "==> Marketing version:               unchanged"
fi
grep -nE 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' "$PROJECT_YML"
