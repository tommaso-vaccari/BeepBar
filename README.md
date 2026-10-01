# BeepBar

[![CI](https://github.com/tommaso-vaccari/BeepBar/actions/workflows/ci.yml/badge.svg)](https://github.com/tommaso-vaccari/BeepBar/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/tommaso-vaccari/BeepBar?label=release)](https://github.com/tommaso-vaccari/BeepBar/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/tommaso-vaccari/BeepBar/total)](https://github.com/tommaso-vaccari/BeepBar/releases)
[![Website](https://img.shields.io/badge/website-BeepBar-1677ff)](https://www.tommasovaccari.com/beepbar)

**[Visit the BeepBar website](https://www.tommasovaccari.com/beepbar)** · **[Download the latest release](https://github.com/tommaso-vaccari/BeepBar/releases/latest)**

Has another syncing app ever **overwritten your annotated slides**? Tired of **renaming files** just to stop them from being replaced? Looking for a syncing app that's **super lightweight** and feels **native** to your macOS environment?

BeepBar solves exactly that. It never overwrites your local work: take notes directly on a slide PDF, or edit a file on iPad/Mac after downloading it, and that copy is preserved instead of being silently replaced when your university platform publishes an update. Built specifically for Apple Silicon, it stays native and ultra-lightweight in the background.

<p align="center">
  <img src="docs/images/courses.png" width="730" alt="The BeepBar window on the Corsi tab: an 'all up to date' status with 12 new and 4 updated files, and the course list, with five of twelve courses turned on, each synced into its own folder.">
</p>
<p align="center"><sub>Pick the courses to sync; each one lands in its own folder. (The app's interface is in Italian.)</sub></p>

## TL;DR / Install

1. [Download Beepbar.dmg](https://github.com/tommaso-vaccari/BeepBar/releases/latest/download/00-Beepbar.dmg), double-click it, then drag BeepBar into Applications. This link always points to the newest release, built automatically from `main`.
2. On first launch, right-click BeepBar and choose **Open**. If macOS blocks it, go to **System Settings > Privacy & Security** and choose **Open Anyway**.
3. Open BeepBar from the menu bar, sign in to WeBeep or Moodle in the browser, and choose the local sync folder.

`Beepbar.dmg` is ad-hoc signed so macOS can verify its integrity, but it is not Developer ID signed or notarized because this project does not use an Apple Developer account. The initial Gatekeeper step in step 2 is therefore expected. If it still blocks the app after moving it into Applications, use this fallback:

```sh
xattr -dr com.apple.quarantine /Applications/Beepbar.app
```

If you're updating from an older version that stored your token in the macOS Keychain, macOS may ask for **Keychain access** once — BeepBar reads that old token a single time to move it into its new local storage, then never touches the Keychain again. Click **Allow**; this only happens once, during that one update.

## How to Use It

- **Menu bar icon**: click it anytime for sync status and a one-click action (sign in, resolve conflicts, sync now). Open the full window with **"Apri BeepBar…"**.
- **Pick your courses**: in **Corsi**, toggle which courses to sync. Each gets its own subfolder inside the root you chose during setup — rename any of them from its **⋯** menu.
- **Sync**: run it manually with **"Sincronizza ora"**, or pick how often to check automatically from the menu under that button (or **"Sincronizzazione automatica"** in Impostazioni), from every 30 minutes to 3 times a day.
- **See what arrived**: after each sync, **Attività** lists the new and updated files, course by course.
- **Resolve conflicts**: when both a local and remote version of a file changed, it shows up in the **Conflitti** section (with a badge count in the menu) — see [How the three-way sync works](#how-the-three-way-sync-works) for what to expect there.
- **Check for updates**: opt in from Impostazioni — see [Auto-updates](#auto-updates).

<p align="center">
  <img src="docs/images/activity.png" width="730" alt="The BeepBar Attività tab after a sync: 12 new, 4 updated, 1 of your edits kept, 0 not updated, with the files that arrived in each course.">
</p>

## Why BeepBar

I wanted something built specifically for macOS: a small app that stays in the menu bar, does not keep a window open, and avoids aggressive background polling. It should be responsive when I need it and quiet when I leave it running throughout the day.

In a preliminary local measurement of the Release build, with automatic sync disabled, BeepBar stayed around 14–15 MiB of memory for 30 minutes with effectively idle CPU use. This is a development reference, not a universal guarantee — but it's the kind of footprint you'd expect from a native Swift app with no bundled runtime, as opposed to Electron/TypeScript-based alternatives, which ship a full Chromium and Node.js runtime and typically carry a much heavier baseline memory and CPU cost.

## Features

- Menu-bar app with clear sync status and contextual actions
- Browser-based login for supported university platforms, with the token stored locally in a permissions-locked file (not the macOS Keychain, so it isn't tied to build-to-build signature changes)
- Manual or configurable automatic sync
- Opens at login by default, so scheduled syncs resume after a restart (switch it off in Impostazioni)
- Controlled parallel downloads, byte-level progress, and real cancellation
- Selectable sync root and editable course-folder names
- [Three-way sync](#how-the-three-way-sync-works) backed by SQLite, atomic staging, and explicit conflict resolution
- [Opt-in auto-updates](#auto-updates) via Sparkle, checked against a signed appcast

## How the three-way sync works

BeepBar keeps a local SQLite baseline for every synced file: the hash and revision it had the moment it was last written to disk. On each sync it compares three states — the baseline, the current local file, and the current remote file:

- **Only the remote changed** → the new version is downloaded and replaces the local copy.
- **Only the local file changed** (you annotated a slide PDF, or edited it on iPad/Mac) → your copy is left untouched, and the baseline is quietly caught up so BeepBar knows your edit is now the source of truth.
- **Both changed** → BeepBar can't safely pick a winner, so it isolates the incoming version and surfaces an explicit conflict: keep your local copy, or switch to the remote one.

Downloads are staged atomically before being installed, so an interrupted sync (crash, closed lid, lost connection) never leaves a half-written file behind.

Open conflicts show up as a badge in the menu bar and in the app's **Conflitti** section — nothing is decided automatically. The incoming remote version is kept isolated on disk (never merged into your local file) until you pick "Mantieni locale" or "Usa versione remota" for each one; only your explicit choice determines which version is kept.

## Auto-updates

BeepBar checks for new builds via [Sparkle](https://sparkle-project.org), against an appcast published alongside every push to `main`. Automatic checks are enabled by default and run every eight hours; you can disable **"Controlla automaticamente"** in Settings or trigger a one-off check with **"Cerca aggiornamenti…"**. Every update is signed with an EdDSA key that never leaves this repo's secrets, and Sparkle verifies that signature before installing anything.

## Requirements

- macOS 14 or later
- Apple Silicon

## Development

```sh
swift test
xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build CODE_SIGNING_ALLOWED=NO
scripts/create-dmg.sh build/Release/Beepbar.app build/Beepbar.dmg
```

CI runs the tests and builds an ad-hoc-signed arm64 DMG.

## Contributing

Found a bug or have a feature request? [Open an issue](https://github.com/tommaso-vaccari/BeepBar/issues). Pull requests are welcome too.

## License

[MIT](LICENSE)

BeepBar is not affiliated with Politecnico di Milano or WeBeep.
