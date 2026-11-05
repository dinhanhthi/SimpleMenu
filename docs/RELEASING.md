# Releasing SimpleMenu

Releases are built, signed, notarized and published from your own Mac. There is no CI and no GitHub Pages: every step runs on this Mac, from the scripts in `scripts/`.

Each release ships two notarized assets on the GitHub Release `vX.Y.Z` of `dinhanhthi/SimpleMenu`:

- `SimpleMenu-X.Y.Z.dmg`: drag-to-install download for new users.
- `SimpleMenu-X.Y.Z.zip`: the Sparkle update archive referenced by the appcast.

## Appcast

- The feed is `appcast.xml` at the repo root, committed on `main`.
- Installed apps read it from `https://raw.githubusercontent.com/dinhanhthi/SimpleMenu/main/appcast.xml` (`SUFeedURL` in `App/Info.plist`).
- `scripts/publish-appcast.sh` regenerates it, commits it as `chore(release): appcast vX.Y.Z` and pushes `main`. That push is the whole deployment.
- raw.githubusercontent.com may cache the file for about 5 minutes.
- Each item's download URL points at the release asset: `https://github.com/dinhanhthi/SimpleMenu/releases/download/vX.Y.Z/SimpleMenu-X.Y.Z.zip`.
- `appcast.xml` does not exist yet: the first `publish-appcast.sh` run creates it.

Check the live feed:

```sh
curl -fsSL https://raw.githubusercontent.com/dinhanhthi/SimpleMenu/main/appcast.xml | grep shortVersionString
```

## §0 One-time setup

Never paste passwords, app-specific passwords or private keys into an AI chat. Run the commands below in your own terminal.

### Tools

- Xcode 27+ selected (`sudo xcode-select -s /Applications/Xcode.app`). The app targets macOS 27 and needs its SDK, and `build-and-notarize.sh` refuses an older Xcode.
- XcodeGen: `brew install xcodegen`. `SimpleMenu.xcodeproj` is generated from `project.yml` and is not in git.
- GitHub CLI: `brew install gh`, then `gh auth login`.

### Apple Developer account and Developer ID certificate

- You need a paid Apple Developer account with Team ID `86H6CNLN4C`. The scripts default to it; another team needs `export TEAM_ID=<10-char team id>`.
- Create a "Developer ID Application" certificate: Xcode > Settings > Accounts > select the team > Manage Certificates > + > Developer ID Application. It must be in the login Keychain. `project.yml` signs Debug with it too, so the Accessibility grant survives rebuilds.
- Verify:

  ```sh
  security find-identity -v -p codesigning
  ```

  The list must contain exactly one `Developer ID Application: ... (86H6CNLN4C)` identity. `build-and-notarize.sh` stops when there is none, and also when there are two (for example an older and a renewed one).

### Notarization credentials

1. Create an app-specific password at account.apple.com > Sign-In and Security > App-Specific Passwords.
2. Store it in a notarytool Keychain profile. notarytool asks for the app-specific password itself, so it never lands in shell history or `ps`:

   ```sh
   xcrun notarytool store-credentials simplemenu-notary --apple-id <email> --team-id 86H6CNLN4C
   ```

To reuse an existing profile of the same team instead (one made for another app, for example), set `NOTARY_PROFILE`. Prefix the command with it, or export it, so that `ship.sh` passes it on to `build-and-notarize.sh`:

```sh
NOTARY_PROFILE=<name> scripts/ship.sh
```

Check the profile with `xcrun notarytool history --keychain-profile simplemenu-notary`.

### Sparkle EdDSA key

Sparkle only installs updates signed with the private key that matches `SUPublicEDKey` in the app. SimpleMenu keeps its key in its own Keychain account, `SimpleMenu`, so it never reuses another app's key stored under Sparkle's default account.

1. Build the app once so Xcode downloads the Sparkle tools into DerivedData (no `-derivedDataPath`: the scripts look in the default DerivedData):

   ```sh
   xcodegen generate
   xcodebuild -project SimpleMenu.xcodeproj -scheme SimpleMenu -configuration Debug build
   ```

2. Find `generate_keys` the same way `scripts/publish-appcast.sh` finds `generate_appcast`, then generate the key pair. The private key goes into the login Keychain, and only the public key is printed:

   ```sh
   G=$(find ~/Library/Developer/Xcode/DerivedData/SimpleMenu-*/SourcePackages/artifacts -name generate_keys -type f 2>/dev/null | head -1)
   "$G" --account SimpleMenu
   ```

   If the `SimpleMenu` account already has a key, this prints its public key and leaves the key unchanged. `"$G" --account SimpleMenu -p` prints the public key only.

3. Paste the public key into the empty `SUPublicEDKey` string in `App/Info.plist`, then commit it on its own:

   ```sh
   git commit -m "chore(release): set Sparkle public key" -- App/Info.plist
   ```

   The key must be committed before a release: `ship.sh` needs a clean tree, and the release commit only holds `CHANGELOG.md` and `project.yml`. While `SUPublicEDKey` is empty, or does not decode from base64 to exactly 32 bytes, `build-and-notarize.sh` refuses to build. The app's updater only starts when the key decodes as base64 to 32 bytes (`App/Updater.swift`); until then "Check for Updates…" stays disabled.

4. Back up the private key. Never commit it, and never print it in a terminal or a chat. Export it into a private temp dir under `umask 077` (not Desktop or Documents: they may sync to iCloud, and a file created before a `chmod` is briefly readable by others). Store its content in a password manager, then delete the file:

   ```sh
   G=$(find ~/Library/Developer/Xcode/DerivedData/SimpleMenu-*/SourcePackages/artifacts -name generate_keys -type f 2>/dev/null | head -1)
   d=$(mktemp -d) && (umask 077 && "$G" --account SimpleMenu -x "$d/sparkle_private_key.txt")
   # copy the content of "$d/sparkle_private_key.txt" into your password manager (do not cat it), then:
   pbcopy </dev/null   # clear the clipboard if you copied the key through it
   rm -f "$d/sparkle_private_key.txt" && rmdir "$d"
   ```

   `rm` does not overwrite the file, and on APFS no `rm` option (`-P` included) reliably wipes it: keep it in the private temp dir and delete it right away.

   `.gitignore` also ignores `sparkle_private_key*` as a safety net.

5. To restore it on another Mac, write the key from the password manager into a fresh private temp dir, import it, then delete the file:

   ```sh
   G=$(find ~/Library/Developer/Xcode/DerivedData/SimpleMenu-*/SourcePackages/artifacts -name generate_keys -type f 2>/dev/null | head -1)
   d=$(mktemp -d) && (umask 077 && pbpaste > "$d/sparkle_private_key.txt")   # key copied from the password manager
   pbcopy </dev/null   # clear the clipboard
   "$G" --account SimpleMenu -f "$d/sparkle_private_key.txt"
   rm -f "$d/sparkle_private_key.txt" && rmdir "$d"
   ```

If you lose the private key, installed apps can no longer accept updates. `generate_appcast` reads the key from the Keychain and may show a Keychain prompt: click Always Allow. Do the same for the `codesign` and `notarytool` prompts.

## §1 Per release

### With /cf-ship (recommended)

Run `/cf-ship`. The project guide `.coding-friend/skills/cf-ship-custom/SKILL.md` checks the setup (branch `main` in sync with `origin/main`, the Developer ID identity, `SUPublicEDKey` against `generate_keys --account SimpleMenu -p`, the notary profile, `gh auth status`). It then picks the version, writes the `CHANGELOG.md` section, bumps `project.yml`, commits `chore(release): vX.Y.Z`, pushes to `main` and runs `scripts/ship.sh`. It can also resume a release that stopped half-way. When it resumes, it pushes unpushed commits only if every one is a `chore(release)` commit touching only `CHANGELOG.md`, `project.yml` and `appcast.xml`, and it publishes the appcast only for the local notarized zip, after checking that its sha256 equals the release asset's (it never signs a downloaded zip).

First release: the current `MARKETING_VERSION` (0.1.0, build 1) ships as-is, without a bump. The `## [Unreleased]` items move into `## [0.1.0] - <date>`, and the `YYYY-MM-DD` placeholder becomes the real date.

### By hand

1. Bump the version, except on the first release. This sets `MARKETING_VERSION` and adds 1 to `CURRENT_PROJECT_VERSION` in `project.yml`:

   ```sh
   scripts/bump-version.sh X.Y.Z
   ```

2. In `CHANGELOG.md`, move the `## [Unreleased]` items into a new `## [X.Y.Z] - YYYY-MM-DD` section with the real date. The GitHub Release notes are the lines between the `## [X.Y.Z]` header and the next `## ` header, with blank lines trimmed at both ends. The section must have content: a header alone fails. `###` subheadings are fine. The scripts do not check the date, so write the real one yourself.
3. Commit and push:

   ```sh
   git add -- CHANGELOG.md project.yml
   git commit -m "chore(release): vX.Y.Z" -- CHANGELOG.md project.yml
   git push origin main
   ```

4. Ship. This builds, notarizes, tags, creates the GitHub Release and publishes the appcast:

   ```sh
   scripts/ship.sh
   ```

   To run the steps one at a time instead:

   ```sh
   scripts/build-and-notarize.sh
   scripts/publish-release.sh release/export/SimpleMenu-X.Y.Z.zip
   scripts/publish-appcast.sh release/export/SimpleMenu-X.Y.Z.zip
   ```

Outputs land in `release/` (gitignored):

- `release/SimpleMenu.xcarchive` and `release/ExportOptions.plist`
- `release/export/`: `SimpleMenu.app`, `SimpleMenu-X.Y.Z.zip`, `SimpleMenu-X.Y.Z.dmg`, and the release notes `SimpleMenu-X.Y.Z.md`, written by `publish-release.sh`
- `release/appcast-archives/`: `publish-appcast.sh`'s working copy

## §2 What each script does

All scripts run from any directory (they `cd` to the repo root) and stop at the first error.

### `scripts/build-and-notarize.sh`

Variables: `TEAM_ID` (default `86H6CNLN4C`), `NOTARY_PROFILE` (default `simplemenu-notary`), `ARCHS` (default `arm64`, or `"arm64 x86_64"` for a universal build). It takes no arguments.

1. It checks the following before anything slow:
   - `TEAM_ID` is a 10-character team id, and `ARCHS` is valid.
   - `xcodebuild` and `xcodegen` are installed, and Xcode is 27+.
   - There is exactly one `Developer ID Application: ... (TEAM_ID)` identity.
   - `SUPublicEDKey` in `App/Info.plist` is not empty and decodes from base64 to exactly 32 bytes, as `App/Updater.swift` requires.
   - `SUFeedURL` is an `https://` URL.
   - The notary profile works (`notarytool history`).
2. It runs `xcodegen generate`. In the Release build settings, `MACOSX_DEPLOYMENT_TARGET` must be `27.0` (`MIN_MACOS`), and an entitlements file, if one is set, must exist and must not have `get-task-allow`. The version comes from `MARKETING_VERSION`.
3. It archives the Release build to `release/SimpleMenu.xcarchive`, with Developer ID signing and `--timestamp`. It uses the default DerivedData.
4. It exports with the `developer-id` method to `release/export/SimpleMenu.app`, pinned to the identity's SHA-1.
5. It re-signs Sparkle's nested helpers inside-out with Developer ID, a secure timestamp and the hardened runtime: `Downloader.xpc`, `Installer.xpc`, `Updater.app`, `Autoupdate`, then the framework, then the app. It finds them through `Sparkle.framework/Versions/Current` and stops if that link cannot be resolved.
6. It checks the exported app:
   - the architectures equal `ARCHS`
   - `Authority` and `TeamIdentifier` belong to `TEAM_ID`
   - the hardened runtime is on
   - `codesign --verify --deep --strict` passes
   - there is no `get-task-allow`
   - `LSMinimumSystemVersion` and the binary's `minos` are both `27.0`
   - the built `SUPublicEDKey` is not empty
7. It zips the app, notarizes the zip (only `Accepted` passes), staples the app, re-zips it as `release/export/SimpleMenu-X.Y.Z.zip` and runs `spctl`.
8. It builds `release/export/SimpleMenu-X.Y.Z.dmg` from the stapled app, with an `/Applications` link. Then it signs, notarizes and staples the DMG and validates it.

### `scripts/publish-release.sh [--yes|-y] [<zip>]`

Variable: `GH_REPO` (default `dinhanhthi/SimpleMenu`). When no zip is given, it uses `release/export/SimpleMenu-<HEAD version>.zip`.

1. It reads the version from `MARKETING_VERSION` in the committed `HEAD:project.yml`, so an uncommitted bump does not count. The zip must be named `SimpleMenu-X.Y.Z.zip` for that version.
2. It takes the release notes from the `## [X.Y.Z]` section of `CHANGELOG.md` (rule in §1). It stops when that section is missing or empty.
3. It checks:
   - the branch is `main`
   - `gh` is authenticated
   - `origin` is `github.com/<GH_REPO>`
   - `HEAD` is on `origin/main`
   - tag `vX.Y.Z` exists neither locally nor on `origin`

   Uncommitted changes to tracked files only print a warning.
4. It asks to confirm, unless you pass `--yes`.
5. It writes the notes to `SimpleMenu-X.Y.Z.md` next to the zip. Then it creates the annotated tag `vX.Y.Z` at `HEAD` and pushes it to `origin`.
6. It runs `gh release create vX.Y.Z <zip> --title "SimpleMenu X.Y.Z" --notes-file SimpleMenu-X.Y.Z.md`. It uploads `SimpleMenu-X.Y.Z.dmg` from the same folder when the file is there; otherwise it prints the `gh release upload` command.

It does not build anything or commit anything.

### `scripts/publish-appcast.sh <zip>`

Variable: `GH_REPO` (default `dinhanhthi/SimpleMenu`). The zip must already be notarized, and the GitHub Release must already exist, because the appcast points at the release asset.

1. It reads the version from the zip name (the first `X.Y.Z` in it), or from `HEAD:project.yml` if the name has none, and stops unless it is `X.Y.Z` digits. The branch must be `main`, and `HEAD` must equal `origin/main` after a `git fetch origin main`, so the push carries the appcast commit only.
2. It finds `generate_appcast` with `find ~/Library/Developer/Xcode/DerivedData/SimpleMenu-*/SourcePackages/artifacts -name generate_appcast -type f`.
3. It creates a fresh `release/appcast-archives/` that holds only the new zip and a copy of the repo-root `appcast.xml`, if that file exists. Older items keep their original download URLs, and the history survives even when `release/` is deleted.
4. It runs `generate_appcast --account SimpleMenu --maximum-deltas 0 --maximum-versions 0 --download-url-prefix https://github.com/<GH_REPO>/releases/download/vX.Y.Z/ --full-release-notes-url https://github.com/<GH_REPO>/releases`. `--maximum-versions 0` keeps every past item, and the update prompt links to the GitHub releases page instead of embedding notes.
5. It copies the result to `appcast.xml` at the repo root, commits only that file as `chore(release): appcast vX.Y.Z`, and runs `git push origin main`.

### `scripts/ship.sh`

Variables: `GH_REPO` (default `dinhanhthi/SimpleMenu`, exported to the scripts it calls). `NOTARY_PROFILE`, `TEAM_ID` and `ARCHS` reach `build-and-notarize.sh` only when they are exported or prefixed on the `ship.sh` command line.

1. It checks the following before building:
   - the branch is `main`
   - `HEAD` equals `origin/main`, after a `git fetch`: only pushed commits ship
   - `gh` is authenticated
   - tracked files have no uncommitted changes (untracked files are ignored)
   - `CHANGELOG.md` has a `## [X.Y.Z]` section with content
   - tag `vX.Y.Z` exists neither locally nor on `origin` (this is the bump check)
2. It runs `build-and-notarize.sh`. It stops without publishing if `HEAD` or a tracked file changed during the build.
3. It runs `publish-release.sh --yes release/export/SimpleMenu-X.Y.Z.zip`, then `publish-appcast.sh release/export/SimpleMenu-X.Y.Z.zip`.
4. It prints the release and appcast URLs.

### `scripts/bump-version.sh [X.Y.Z]`

It always adds 1 to `CURRENT_PROJECT_VERSION` (the build number), because Sparkle only offers an update when the build number grows. When a version is given (`X.Y.Z` digits only), it also sets `MARKETING_VERSION`. It edits `project.yml` with `perl` (`PROJECT_YML` can point at another file, for tests) and prints the new values. It does not commit.

## §3 Troubleshooting and rollback

### Build and notarization

- `Xcode 27+ required`: run `sudo xcode-select -s /Applications/Xcode.app`. It must point at Xcode 27 or later.
- `no 'Developer ID Application: ... (86H6CNLN4C)' identity`: create the certificate (§0). If the error says the identity is `ambiguous`, delete the old certificate so only one is listed by `security find-identity -v -p codesigning`.
- `SUPublicEDKey is empty` or `is not a base64 32-byte EdDSA public key`: do the Sparkle key step (§0), paste the exact output of `generate_keys --account SimpleMenu -p`, and commit `App/Info.plist`.
- `notarytool credential profile 'simplemenu-notary' is missing or invalid`: run `store-credentials` (§0), or set `NOTARY_PROFILE`.
- `notarization not Accepted`: the script prints the command for the log, which names the binary that failed:

  ```sh
  xcrun notarytool log <id> --keychain-profile simplemenu-notary
  ```

- Gatekeeper check of the app or the DMG:

  ```sh
  spctl -a -vvv release/export/SimpleMenu.app
  spctl -a -vvv -t open --context context:primary-signature release/export/SimpleMenu-X.Y.Z.dmg
  ```

  The app must report `source=Notarized Developer ID`. If Gatekeeper still blocks a downloaded copy, check that the release assets are the stapled files from `release/export/`.
- `generate_appcast not found in DerivedData`: build the project once (§0, Sparkle EdDSA key, step 1).

### Publishing

- `HEAD (...) is not origin/main`: push the release commit, or run `git fetch origin && git merge --ff-only origin/main`. If the fast-forward fails, `main` has diverged: rebase or merge by hand, then release again. Never force-push `main`.
- `source changed during build; release was not published`: something committed or edited tracked files while `ship.sh` was building. Nothing was tagged. Clean up and run `scripts/ship.sh` again.
- `gh release create failed. The tag vX.Y.Z was already pushed.`: `publish-release.sh` pushes the tag before it creates the release, so a failed `gh release create` leaves the tag on `origin`. A new `ship.sh` run then stops with `tag vX.Y.Z already exists`. Fix the cause (often `gh` auth or the network), then finish the release with the files that are already in `release/export/`:

  ```sh
  gh release create vX.Y.Z release/export/SimpleMenu-X.Y.Z.zip --repo dinhanhthi/SimpleMenu \
    --title "SimpleMenu X.Y.Z" --notes-file release/export/SimpleMenu-X.Y.Z.md
  gh release upload vX.Y.Z release/export/SimpleMenu-X.Y.Z.dmg --repo dinhanhthi/SimpleMenu
  scripts/publish-appcast.sh release/export/SimpleMenu-X.Y.Z.zip
  ```

  Or drop the tag and start again: `git push origin :refs/tags/vX.Y.Z && git tag -d vX.Y.Z`.
- `tag vX.Y.Z already exists` for a release that is half-shipped (the tag is pushed, but an asset or the appcast entry is missing): finish it.
  - If the GitHub Release itself is missing, run the `gh release create` command above. If `release/export/SimpleMenu-X.Y.Z.md` is gone, save the `## [X.Y.Z]` section of `CHANGELOG.md` to a file and pass that file instead.
  - Upload any missing asset with `gh release upload vX.Y.Z release/export/<missing file> --repo dinhanhthi/SimpleMenu`.
  - Check that the release asset is byte for byte the local notarized zip. Download it into a temp dir, never over `release/export/`, and compare the hashes:

    ```sh
    T=$(mktemp -d) && gh release download vX.Y.Z --repo dinhanhthi/SimpleMenu --pattern 'SimpleMenu-X.Y.Z.zip' --dir "$T" && { [ "$(shasum -a 256 < release/export/SimpleMenu-X.Y.Z.zip)" = "$(shasum -a 256 < "$T/SimpleMenu-X.Y.Z.zip")" ] && echo MATCH || echo MISMATCH; }; rm -rf "$T"
    ```

    It must print `MATCH`. If it prints `MISMATCH` or the download fails, stop: do not publish the appcast, check the release by hand or roll it back (below).
  - If `release/export/` no longer holds the zip, do not sign a downloaded copy: roll the release back (below) and ship again.
  - Then run `scripts/publish-appcast.sh release/export/SimpleMenu-X.Y.Z.zip` on the local zip.

  `/cf-ship` can resume these cases on its own. Otherwise, bump the version, or roll back the bad release (below).
- The appcast commit was made, but the push failed: run `git push origin main`. You do not need to run `publish-appcast.sh` again: it would stop, because `HEAD` is not `origin/main` while the appcast commit is unpushed.
- Push rejected (non-fast-forward): local `main` is behind `origin/main`. See the `HEAD (...) is not origin/main` entry above.

### Updates not offered

- Check that the feed is live (the `curl` in Appcast), and remember the cache of about 5 minutes.
- Check that the build number (`CURRENT_PROJECT_VERSION`) grew.
- Check that `SUPublicEDKey` in `App/Info.plist` equals `generate_keys --account SimpleMenu -p`.
- If "Check for Updates…" is disabled in the installed app, the key in its Info.plist is not a base64 32-byte key. Console shows `Updater off: SUPublicEDKey is not a base64 32-byte EdDSA public key` (subsystem `com.math2it.simplemenu`).

### Roll back a bad release

```sh
gh release delete vX.Y.Z --repo dinhanhthi/SimpleMenu
git push origin :refs/tags/vX.Y.Z && git tag -d vX.Y.Z
git log --format='%h %s' -- appcast.xml          # find "chore(release): appcast vX.Y.Z"
git revert <appcast-commit>
git push origin main
```

Reverting the appcast commit stops the update from being offered to installed apps. Users who already updated keep that version, so ship a fixed version with a higher build number (`scripts/bump-version.sh X.Y.Z`) to move them on. On the first release, the revert deletes `appcast.xml`: the feed returns 404 until the next `publish-appcast.sh` run creates it again.

### Known gaps

- `publish-release.sh` pushes the tag before `gh release create` (Phase 2 follow-up, still open). See the recovery steps above.
- `build-and-notarize.sh` does not check that `SUPublicEDKey` matches the Keychain key: `/cf-ship` checks the match.
- No script checks the CHANGELOG date. A `YYYY-MM-DD` placeholder would ship as-is.
