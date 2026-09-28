<div align="center">

<img src="docs/assets/logo.png" width="128" height="128" alt="CareMyMac app icon">

# CareMyMac

**Everything your Mac is doing. App by app.**

A native macOS activity monitor organized around apps, with a 30-day timeline that never leaves your Mac.

[![Latest release](https://img.shields.io/github/v/release/rohmanhm/caremymac?label=release&color=2f7cf6)](https://github.com/rohmanhm/caremymac/releases/latest)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111?logo=apple)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-f05138?logo=swift&logoColor=white)
![No telemetry](https://img.shields.io/badge/telemetry-none-2ea44f)

[**Download for Mac**](https://github.com/rohmanhm/caremymac/releases/latest) · [Features](#features) · [Build from source](#build-and-run)

<a href="docs/assets/caremymac-intro.mp4"><img src="docs/assets/intro-poster.png" width="860" alt="Watch the CareMyMac intro video"></a>

<sub><a href="docs/assets/caremymac-intro.mp4">Watch the 30-second intro</a></sub>

</div>

Pick an app and see everything it's doing: CPU, memory and disk over the last few minutes, and every helper process macOS runs for it. CareMyMac also keeps a per-minute timeline for 30 days, entirely on your Mac, and helps you tidy up: caches, leftovers of uninstalled apps, launch agents, and the process squatting on port 3000.

## Features

### Overview

Where the window opens (⌘1). A tile per resource with its current value and recent trail (CPU, Memory, Disk, Network, startup disk free space, and Graphics and Battery when this Mac reports them), the five busiest apps, and the latest alerts and markers. Every tile and row opens the page it summarizes.

<img src="docs/assets/screenshots/overview.png" alt="Overview: resource tiles, top apps, alerts and markers">

### Apps and Background

App lists sorted by CPU, memory, disk or name, with an impact meter per row. **Busy Only** narrows Apps to the ones using at least 1% of a core or 1 MB/s of disk right now. The selected app shows live charts, its processes, and Show in Finder, Quit and Force Quit. Helpers are grouped under their app by bundle, parent process, and the process macOS holds responsible.

<img src="docs/assets/screenshots/apps.png" alt="Apps: Ghostty selected with its CPU, memory and disk charts and 48 processes">

### Developer and Free a Port

Dev runtimes (Node, Python, Bun, Go, …) grouped by working folder, with their listening ports. **Free a Port** finds whatever listens on a port, list or range (`3000, 5173`, `8000-8010`) in any process you own, and stops or force stops it; ports held by root or other users are flagged as in use.

<img src="docs/assets/screenshots/developer.png" alt="Developer: Free a Port and runtimes grouped by folder">

### This Mac

Every resource on one clock (1, 5 or 10 minutes), one hover cursor for all of them, and the top apps underneath. Tabs for CPU, Memory, Disk, Network, Graphics and Battery go into detail.

<img src="docs/assets/screenshots/thisMac.png" alt="This Mac: CPU, memory, disk, network, graphics and battery on one clock">

<table>
  <tr>
    <td width="50%"><img src="docs/assets/screenshots/thisMac-cpu.png" alt="This Mac, CPU tab"></td>
    <td width="50%"><img src="docs/assets/screenshots/thisMac-memory.png" alt="This Mac, Memory tab"></td>
  </tr>
  <tr>
    <td align="center"><sub>CPU: user, system, load and per-core use</sub></td>
    <td align="center"><sub>Memory: pressure, swap and what the memory holds</sub></td>
  </tr>
</table>

### Storage

A folder-by-folder index of your home folder (or any folder you choose), with categories.

<img src="docs/assets/screenshots/storage.png" alt="Storage: category donut and the largest folders">

### Timeline

One sample per minute for 30 days, a chart per metric, and the top apps at any minute.

<img src="docs/assets/screenshots/timeline.png" alt="Timeline: CPU over 12 hours with the top apps at the selected time">

### Alerts and Markers

**Alerts** are rules for sustained app CPU, memory growth, pressure, battery and more, with optional macOS notifications. **Markers** flag a point in time (⇧⌘S): a marker keeps the 2 minutes before it and 30 seconds after, with the top apps.

<img src="docs/assets/screenshots/alerts.png" alt="Alerts: an app whose memory grew in the last hour">

### Cleanup

User caches, logs, developer build products and package caches (Xcode Derived Data, npm, Homebrew, …), and old installers in Downloads, measured by allocated size. Selected items move to the Trash; caches of running apps and your own downloads start unselected. Empty Trash is the one permanent deletion and asks first.

<img src="docs/assets/screenshots/cleanup.png" alt="Cleanup: caches, logs and developer files with their sizes">

### Uninstaller

The apps in /Applications and ~/Applications with their size and when you last opened them, and each app's leftovers in your Library, matched by exact bundle ID or name. The app and the leftovers you pick move to the Trash; apps an installer owns as the system move with your administrator password.

<img src="docs/assets/screenshots/uninstaller.png" alt="Uninstaller: an app with its leftovers in the Library">

### Optimize

Launch agents and daemons with the app each belongs to, whether it runs and whether it starts at login; disable, enable or remove your own agents (system items are read-only). Maintenance tasks (Flush DNS Cache, Free Up Memory, Reindex Spotlight, Rebuild Launch Services Database, Thin Time Machine Local Snapshots), each explained, some behind your administrator password. Apps using at least 50% of a core or 2 GB of memory right now.

<img src="docs/assets/screenshots/optimize.png" alt="Optimize: login and background items with their apps">

### Welcome

The first time CareMyMac runs, a sheet over the main window shows what sets it apart (apps with their helpers, one clock and markers, alerts, Free a Port, Care that moves things to the Trash) in five illustrated steps with Back, Continue, Skip Intro and a dot per step. The last step offers the four choices that change how it keeps watch: open at login, keep running in the menu bar, alert notifications, and Full Disk Access. Each is optional and also in Settings; a permission is asked for only when you turn its switch on. Help ▸ Welcome to CareMyMac shows it again. Copies that already have a history never see it on their own.

<table>
  <tr>
    <td width="50%"><img src="docs/assets/screenshots/welcome.png" alt="Welcome sheet, first step"></td>
    <td width="50%"><img src="docs/assets/screenshots/welcome-setup.png" alt="Welcome sheet, setup step"></td>
  </tr>
</table>

### And also

- **Menu bar extra** and **Settings**: refresh rate, open at login, menu bar metric and style.
- **Share a summary**: File ▸ Share Summary… and Copy Summary (⇧⌘C) export a text summary.
- **Updates**: once a day CareMyMac checks the latest GitHub release and, when there's a newer version, shows it with its release notes and offers Install Update, Remind Me Later or Skip This Version. CareMyMac ▸ Check for Updates… checks now. A waiting update also shows in the menu bar panel and in Settings, where automatic checks and automatic installs can be turned off.

## Privacy

Nothing leaves the Mac: no account, no telemetry. The update check downloads `appcast.xml` from GitHub and sends nothing about you or your Mac. Data lives in `~/Library/Application Support/CareMyMac/`.

## Install

Download `CareMyMac-<version>.dmg` from the [latest release](https://github.com/rohmanhm/caremymac/releases/latest), open it and drag CareMyMac to Applications. Releases are signed with a Developer ID and notarized by Apple, and update themselves from then on.

## Requirements

macOS 26 or later, Xcode 26.

## Build and run

With [just](https://github.com/casey/just) (`brew install just`):

```sh
just run            # build Debug, quit any running copy, launch
just release        # same with the optimized Release build
just dev            # run in the foreground with logs in the terminal
just test           # engine tests
just snapshot busy,thisMac:cpu light   # render pages to PNG (Debug)
just xcode          # open in Xcode
just clean          # remove build products
just package 0.2.0  # build the update zip, signed appcast and notarized disk image into build/release
just dmg            # Release build in an unsigned disk image at build/CareMyMac.dmg, to check its layout
just publish 0.2.0  # tag v0.2.0 and push it; GitHub Actions publishes the release
```

Or open `CareMyMac.xcodeproj` in Xcode and press ⌘R.

## Layout

| Path | What |
| --- | --- |
| `Packages/CareMyMacKit/Sources/CareMyMacKit` | Engine: samplers (`System/`, `Activity/`), SQLite history, alerts, markers (`Store/`, stored as `SavedMoment`), storage indexer (`StorageIndex/`), Cleanup, Uninstaller and Optimize scanners and commands (`Care/`), `MonitorEngine` actor |
| `Packages/CareMyMacKit/Sources/CareMyMacUI` | `LiveMonitor` (observable live state and per-app trails), OKLCH palette, formatters, shared chart and card components |
| `CareMyMac/` | App target: pages (`Screens/`), the app browser and shared views (`Views/`), settings, menu bar, app wiring |
| `docs/assets/` | README logo, intro video and poster, and screenshots (`screenshots/`, dark pages from `just snapshot`, welcome steps from `-CareMyMacShowOnboarding`) |

The app isn't sandboxed: reading other processes' CPU, memory and ports, quitting apps, and cleaning other apps' caches and leftovers require that. Some Cleanup and Uninstaller folders are protected by macOS; grant Full Disk Access in System Settings ▸ Privacy & Security to see them.

## Releases and updates

Updates use [Sparkle](https://sparkle-project.org). Installed copies read the feed at `https://github.com/rohmanhm/caremymac/releases/latest/download/appcast.xml` (`SUFeedURL` in `CareMyMac/Info.plist`) and install an update only if its EdDSA signature matches `SUPublicEDKey`.

To release, run `just publish 0.2.0` (or create a release with a new `v0.2.0` tag in GitHub). `.github/workflows/release.yml` then runs `scripts/release.sh`: it archives a universal Release app with version 0.2.0, exports it signed with the Developer ID Application certificate of team `NJVVS6LHNX`, has Apple notarize it and staples the ticket, zips it, and writes `appcast.xml` with the release notes and the zip's signature, made with the `SPARKLE_PRIVATE_KEY` repository secret. It then puts the stapled app in `CareMyMac-0.2.0.dmg`, signs the disk image with the same certificate, and has it notarized and stapled too. The workflow attaches `CareMyMac-0.2.0.dmg`, `CareMyMac-0.2.0.zip` and `appcast.xml` to the release. Notes you wrote on the release are kept; otherwise GitHub generates them. The version comes from the tag, and the build number matches it.

The disk image is the download for new installs: opening it shows CareMyMac beside a link to Applications, with an arrow and "Drag CareMyMac to Applications to install" between them. `scripts/dmg.sh` builds it with [dmgbuild](https://github.com/dmgbuild/dmgbuild), run through `pipx` (preinstalled on GitHub's macOS runners, `brew install pipx` locally), which writes the Finder layout without opening Finder. The window size and icon positions are in `scripts/dmg-settings.py`; `scripts/dmg-background.swift` draws the background at 1x and 2x to match them. Updates keep using the zip.

The workflow needs these repository secrets (Settings ▸ Secrets and variables ▸ Actions, or `gh secret set NAME`):

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | The Developer ID Application certificate with its private key, exported from Keychain Access as a `.p12`, base64-encoded: `base64 -i DeveloperID.p12 \| gh secret set DEVELOPER_ID_CERTIFICATE_P12` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password chosen when exporting the `.p12` |
| `NOTARY_KEY_P8` | An App Store Connect API key with the Developer role (App Store Connect ▸ Users and Access ▸ Integrations ▸ Team Keys), the downloaded `AuthKey_<id>.p8` as is: `gh secret set NOTARY_KEY_P8 < AuthKey_<id>.p8` |
| `NOTARY_KEY_ID` | That key's Key ID |
| `NOTARY_ISSUER_ID` | The Issuer ID shown above the team keys |
| `SPARKLE_PRIVATE_KEY` | The EdDSA key that signs updates, below |

The private key is also in the login keychain of the Mac that created it, under the account `caremymac` (Sparkle's `generate_keys --account caremymac`, in `build/DD/SourcePackages/artifacts/sparkle/Sparkle/bin`). `just package` signs with it locally, after macOS asks to allow keychain access. It notarizes with the notarytool profile `caremymac`, stored once with `xcrun notarytool store-credentials caremymac --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer>`. If the EdDSA key is lost, installed copies can't verify new updates and have to be updated by hand once.

The feed has to be downloadable without signing in, so the repository must be public; while it's private, update checks fail quietly. Release builds, including `just release`, sign with the Developer ID, so the certificate must be in the keychain. Debug builds are ad-hoc signed without the hardened runtime, which would refuse to load Sparkle.framework without a Team ID. Versions up to 0.2.0 were ad-hoc signed: updating from them to a Developer ID build works because the EdDSA key is unchanged, but macOS privacy grants such as Full Disk Access have to be given once more.

## Debug-only launch arguments

Debug builds can render pages to PNG for visual checks without Screen Recording permission:

```sh
CareMyMac.app/Contents/MacOS/CareMyMac -CareMyMacStore /tmp/test.sqlite \
  -CareMyMacSnapshotDir /tmp/shots -CareMyMacSnapshotScreens busy,thisMac,thisMac:cpu,timeline \
  -CareMyMacSnapshotWarmup 30 -CareMyMacAppearance dark
```

`-CareMyMacStore` keeps test runs out of your real history. Screen names are the sidebar sources: `overview`, `apps`, `background`, `developer`, `thisMac`, `storage`, `timeline`, `alerts`, `markers`, `cleanup`, `uninstaller`, `optimize`. `thisMac:<tab>` picks a tab (`all`, `cpu`, `memory`, `disk`, `network`, `graphics`, `battery`); `apps:busy` turns on Busy Only; app lists open on their top app. `:wait` waits 12 s before capturing. `-CareMyMacSnapshotScrollToEnd YES` scrolls Overview and Markers to the bottom when they open.

`-CareMyMacShowOnboarding YES` shows the welcome sheet at launch (with `-CareMyMacSnapshotDir` it's captured as `<screen>-sheet.png`); otherwise snapshot runs never show it. `-CareMyMacOnboardingStep <step>` opens it on `welcome`, `timeline`, `alerts`, `developer`, `care` or `setup`.

Debug builds don't check for updates on a schedule, since a release would replace them. `-CareMyMacFeedURL <url>` points one at a test feed, and `-CareMyMacCheckForUpdates YES` runs Check for Updates… at launch; with `-CareMyMacSnapshotDir` it also saves the update prompt as `update.png` and the menu bar panel as `menubar-update.png`.
