# CareMyMac

A native macOS activity monitor organized around apps. Pick an app and see everything it's doing: CPU, memory and disk over the last few minutes, and every helper process macOS runs for it. CareMyMac also keeps a per-minute timeline for 30 days, entirely on your Mac.

- **Busy Now, All Apps, Background**: app lists sorted by CPU, memory, disk or name, with an impact meter per row. The selected app shows live charts, its processes, and Show in Finder, Quit and Force Quit. Helpers are grouped under their app by bundle, parent process, and the process macOS holds responsible.
- **Developer**: dev runtimes (Node, Python, Bun, Go, …) grouped by working folder, with their listening ports. **Free a Port** finds whatever listens on a port, list or range (`3000, 5173`, `8000-8010`) in any process you own, and stops or force stops it; ports held by root or other users are flagged as in use.
- **This Mac**: every resource on one clock (1, 5 or 10 minutes), one hover cursor for all of them, and the top apps underneath. Tabs for CPU, Memory, Disk, Network, Graphics and Battery go into detail.
- **Storage**: a folder-by-folder index of your home folder (or any folder you choose), with categories.
- **Timeline**: one sample per minute for 30 days, a chart per metric, and the top apps at any minute.
- **Alerts**: rules for sustained app CPU, memory growth, pressure, battery and more, with optional macOS notifications.
- **Markers**: flag a point in time (⇧⌘S). A marker keeps the 2 minutes before it and 30 seconds after, with the top apps.
- **Menu bar extra** and **Settings** (refresh rate, open at login, menu bar metric and style). File ▸ Share Summary… / Copy Summary (⇧⌘C) export a text summary.
- **Cleanup**: user caches, logs, developer build products and package caches (Xcode Derived Data, npm, Homebrew, …), and old installers in Downloads, measured by allocated size. Selected items move to the Trash; caches of running apps and your own downloads start unselected. Empty Trash is the one permanent deletion and asks first.
- **Uninstaller**: the apps in /Applications and ~/Applications with their size and when you last opened them, and each app’s leftovers in your Library, matched by exact bundle ID or name. The app and the leftovers you pick move to the Trash; apps an installer owns as the system move with your administrator password.
- **Optimize**: launch agents and daemons with the app each belongs to, whether it runs and whether it starts at login; disable, enable or remove your own agents (system items are read-only). Maintenance tasks (Flush DNS Cache, Free Up Memory, Reindex Spotlight, Rebuild Launch Services Database, Thin Time Machine Local Snapshots), each explained, some behind your administrator password. Apps using at least 50% of a core or 2 GB of memory right now.

Nothing leaves the Mac: no account, no telemetry. Data lives in `~/Library/Application Support/CareMyMac/`.

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
```

Or open `CareMyMac.xcodeproj` in Xcode and press ⌘R.

## Layout

| Path | What |
| --- | --- |
| `Packages/CareMyMacKit/Sources/CareMyMacKit` | Engine: samplers (`System/`, `Activity/`), SQLite history, alerts, markers (`Store/`, stored as `SavedMoment`), storage indexer (`StorageIndex/`), Cleanup, Uninstaller and Optimize scanners and commands (`Care/`), `MonitorEngine` actor |
| `Packages/CareMyMacKit/Sources/CareMyMacUI` | `LiveMonitor` (observable live state and per-app trails), OKLCH palette, formatters, shared chart and card components |
| `CareMyMac/` | App target: pages (`Screens/`), the app browser and shared views (`Views/`), settings, menu bar, app wiring |

The app isn't sandboxed: reading other processes' CPU, memory and ports, quitting apps, and cleaning other apps' caches and leftovers require that. Some Cleanup and Uninstaller folders are protected by macOS; grant Full Disk Access in System Settings ▸ Privacy & Security to see them.

## Debug-only launch arguments

Debug builds can render pages to PNG for visual checks without Screen Recording permission:

```sh
CareMyMac.app/Contents/MacOS/CareMyMac -CareMyMacStore /tmp/test.sqlite \
  -CareMyMacSnapshotDir /tmp/shots -CareMyMacSnapshotScreens busy,thisMac,thisMac:cpu,timeline \
  -CareMyMacSnapshotWarmup 30 -CareMyMacAppearance dark
```

`-CareMyMacStore` keeps test runs out of your real history. Screen names are the sidebar sources: `busy`, `allApps`, `background`, `developer`, `thisMac`, `storage`, `timeline`, `alerts`, `markers`, `cleanup`, `uninstaller`, `optimize`. `thisMac:<tab>` picks a tab (`all`, `cpu`, `memory`, `disk`, `network`, `graphics`, `battery`); app lists open on their top app. `:wait` waits 12 s before capturing.
