---
name: release-lotion
description: "Release the Lotion macOS notes app to GitHub using the lotion-release CLI tool. Use this skill whenever the user wants to publish a new version, create a release, ship an update, cut a build, push a release to GitHub, or update the appcast. Also use when they mention archiving, notarization, DMG creation, Sparkle signing, bumping the version/build, the Homebrew cask, or anything related to building and distributing a new Lotion version."
---

# Release Lotion

This skill releases new versions of Lotion using a custom Go CLI
(`cmd/lotion-release`). The CLI can run **fully automated and
non-interactively**, so a release can be triggered directly from a chat session
(the agent can run it end to end).

There are two modes:

- **Full auto (`-build`)** - archive, export (Developer ID), notarize, staple,
  package, sign, and publish. Nothing in Xcode's GUI is required.
- **Package-only** (no `-build`) - assumes the user already exported a
  notarized `~/Downloads/Lotion.app` from Xcode, then packages & publishes.

Prefer **full auto** unless the user says they've already exported the app.

## Prerequisites

Always required:

1. Tools installed: `create-dmg` (brew), `gh` (GitHub CLI, authenticated), `git`, `plutil`, `go`.
2. The Sparkle `sign_update` binary in DerivedData (created when the project is
   built/archived - the `-build` flow produces it automatically).
3. The Sparkle EdDSA private key in the login keychain (shared with Screendrop;
   `generate_keys -p` must print the `SUPublicEDKey` below).
4. [shiki-swift](https://github.com/fayazara/shiki-swift) cloned at
   `../shiki-swift` - the project uses it as a local package.

For **full auto (`-build`)** additionally:

5. `xcodebuild`, `xcrun`, `ditto` (Xcode 27; the CLI points `DEVELOPER_DIR` at
   `/Applications/Xcode.app` itself if the active dir is Command Line Tools).
6. A **notarytool keychain profile**. The default is `screendrop-notary` - an
   App Store Connect API key for team `TB2S44TFQS`, shared with Screendrop. If
   it is missing, create it (or another name, passed with `-notary-profile`):
   ```bash
   xcrun notarytool store-credentials "screendrop-notary" \
     --key /path/to/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

## The Release CLI

Source: `/Users/fayazahmed/Developer/fayazara/mac/Paper/cmd/lotion-release/`

### Flags

- `-build` - run the archive → export → notarize → staple phase first.
- `-set-version <x.y.z>` - set `MARKETING_VERSION` before archiving (and commit it). Used with `-build`.
- `-set-build <n>` - set `CURRENT_PROJECT_VERSION` before archiving (and commit it). Used with `-build`.
- `-scheme <name>` - Xcode scheme to archive (default `Lotion`; never `Lotion Demo`).
- `-notes "<text>"` - release notes, one bullet per line (markdown `- ` prefixes are stripped). Skips the interactive prompt.
- `-notes-file <path>` - read release notes from a file instead.
- `-notary-profile <name>` - notarytool keychain profile (default `screendrop-notary`).
- `-yes` / `-y` - assume "yes" for all confirmation prompts (non-interactive).

### Triggering a full release from here (recommended)

1. **Decide the version and build number.** The build number
   (`CURRENT_PROJECT_VERSION`) **must increase** every release or Sparkle won't
   offer the update. Check the current values (the project uses Xcode's
   JSON-style `project.xcproj`, not a `project.pbxproj`):
   ```bash
   grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" \
     Lotion.xcodeproj/project.xcproj | sort -u
   ```
   Pick the next `MARKETING_VERSION` (real dotted semver like `0.2.1`, never
   regress) and `CURRENT_PROJECT_VERSION` = current + 1.
2. **Write release notes** from the commits since the last tag
   (`git log $(git describe --tags --abbrev=0)..HEAD --oneline`), in plain,
   user-facing language - one bullet per change worth telling users about.
3. **Make sure code changes are committed and pushed** to `main` first, so the
   release tag points at the released source. (The CLI commits the version bump
   and pushes it and the appcast, but it does not commit your other changes.)
4. **Run it** (non-interactive and safe to run from a tool call):
   ```bash
   cd /Users/fayazahmed/Developer/fayazara/mac/Paper && \
   go run ./cmd/lotion-release -build -yes \
     -set-version <x.y.z> -set-build <n> \
     -notes "First note
   Second note"
   ```
   Archiving plus notarization takes several minutes - this is expected, not a
   hang. Run it in the background or with a generous timeout (~10 min).

### Package-only (app already exported by the user)

```bash
cd /Users/fayazahmed/Developer/fayazara/mac/Paper && \
go run ./cmd/lotion-release -yes -notes "Your notes here"
```

### What it does (in order)

With `-build`:
1. **Set version/build** (if `-set-version`/`-set-build` given) - edits `project.xcproj` and commits.
2. **Archive** - `xcodebuild archive` (scheme `Lotion`, Release, `generic/platform=macOS`).
3. **Export** - `xcodebuild -exportArchive` with a generated Developer ID `ExportOptions.plist`.
4. **Notarize** - zips the app and runs `xcrun notarytool submit --wait`, verifying `status: Accepted`.
5. **Staple** - `xcrun stapler staple`, then places the app at `~/Downloads/Lotion.app`.

Then always:
6. **Preflight checks** + **validate** the app's version/build and Sparkle keys.
7. **Collect release notes** (from `-notes`/`-notes-file`, else stdin).
8. **Create DMG** with `create-dmg` → `~/Downloads/Lotion.dmg`.
9. **Sign DMG** with Sparkle `sign_update` (EdDSA).
10. **Push commits** - push local commits (e.g. the version bump) to `main`.
11. **GitHub release** - `gh release create vX.Y.Z` with the DMG attached.
12. **Update + push appcast.xml** - prepend the new `<item>` (de-duping any entry for the same build), commit & push to `main`.
13. **Homebrew cask** - regenerate and push `Casks/lotion.rb` to `fayazara/homebrew-tap` (non-fatal).

**Ordering & robustness:** the release is created **before** the appcast is
pushed, so a published appcast never points at a missing release. Network
operations (`gh`, `git push`) are retried with backoff. Re-running a release is
safe: an existing GitHub release gets the DMG re-uploaded (`--clobber`) and the
appcast entry for that build is replaced rather than duplicated.

### Environment / constants

- Repo auto-detected from the working directory, else `~/Developer/fayazara/mac/Paper` (override with `LOTION_REPO`).
- GitHub repo: `fayazara/Lotion` · branch: `main` · team: `TB2S44TFQS` · bundle: `com.fayazahmed.Lotion`.
- DMG volume: `Lotion` · minimum macOS: `27.0`.
- Homebrew tap clone: temporary, or a local clone via `LOTION_TAP_DIR`.

## Sparkle Configuration

- **Config/Info.plist** (merged into the generated Info.plist via `INFOPLIST_FILE`):
  - `SUFeedURL`: `https://raw.githubusercontent.com/fayazara/Lotion/main/appcast.xml`
  - `SUPublicEDKey`: `MA/6n0fqT0T2updDlkXr8BjhJKoHWik9uf6Lh5pUG7U=`
  - `SUEnableInstallerLauncherService`: `YES` (required because Lotion is sandboxed)
- **Config/Lotion.entitlements** - sandbox, network client, user-selected files,
  plus the `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` / `-spki` mach-lookup exceptions
  Sparkle's installer needs inside the sandbox. Keep these files outside the
  `Lotion/` folder: that folder is synchronized into the target, so anything in
  it is copied into the app as a resource.
- **Lotion/App/UpdaterManager.swift** - singleton started from
  `AppDelegate.applicationDidFinishLaunching` (Release builds only; Debug builds
  never check). UI: **Lotion → Check for Updates…** and **Settings → Updates**.

## After releasing

Verify the release succeeded:
```bash
gh release view v<x.y.z> --repo fayazara/Lotion --json tagName,assets -q '{tag: .tagName, assets: [.assets[].name]}'
curl -s https://raw.githubusercontent.com/fayazara/Lotion/main/appcast.xml | grep -E "shortVersionString|url="
```
The CLI pushes the appcast commit itself, so run `git pull --ff-only origin main`
afterward to sync your local `main` if the release ran from another checkout.

## Troubleshooting

- **Partial failure / network error mid-release** - re-run the exact same command. The pipeline is idempotent.
- **notarytool credentials error** - the keychain profile is missing/invalid; have the user re-run `store-credentials`.
- **Notarization "Invalid"** - inspect with `xcrun notarytool log <submission-id> --keychain-profile screendrop-notary` (usually signing/entitlements, e.g. an unsigned nested binary).
- **`xcodebuild archive` fails** - the CLI prints the last ~40 lines. Check `../shiki-swift` exists and the scheme is `Lotion`.
- **Lotion.app not found** (package-only mode) - export from Xcode first, or use `-build`.
- **sign_update not found** - build/archive the project once so DerivedData has the Sparkle artifacts.
- **Update downloads but fails to install** - the sandbox pieces are missing: check `SUEnableInstallerLauncherService` in the built Info.plist and the `-spks`/`-spki` entitlements (`codesign -d --entitlements - Lotion.app`).
- **gh auth** - run `gh auth login`.
- **Build already in appcast** - a *new* release needs a higher build number; bump `-set-build`.
