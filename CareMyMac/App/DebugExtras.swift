#if DEBUG
import AppKit
import CareMyMacKit
import CareMyMacUI
import SwiftUI
import UserNotifications

/// Debug-only verification for Settings, the menu bar panel, and window cadence.
///
///     CareMyMac -CareMyMacSnapshotDir /tmp/shots -CareMyMacSnapshotScreens thisMac -CareMyMacSnapshotWarmup 20 \
///             -CareMyMacOpenSettings YES
///
/// Shortly before `DebugSnapshot` captures its pages, opens Settings and writes `settings.png`, `menubar.png`
/// (the panel hosted offscreen) and `statusitem.png` into the snapshot folder.
/// `-CareMyMacLogVisibility YES` prints the refresh interval and the app's windows whenever visibility changes.
/// `-CareMyMacCheckIntegration YES` hides and re-shows the menu bar extra, then sends a test alert through the notifier.
/// `-CareMyMacCheckForUpdates YES` runs Check for Updates… at launch; with `-CareMyMacSnapshotDir` it writes Sparkle's
/// prompt to `update.png` and the menu bar panel with its update row to `menubar-update.png`. Point it at a test feed
/// with `-CareMyMacFeedURL <url>`.
@MainActor
enum DebugExtras {
    static func runIfRequested(delegate: AppDelegate) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "CareMyMacLogVisibility") { logVisibility(monitor: delegate.monitor) }
        if defaults.bool(forKey: "CareMyMacCheckIntegration") { checkIntegration(delegate: delegate) }
        if defaults.bool(forKey: "CareMyMacCheckForUpdates") { checkForUpdates(delegate: delegate, directory: defaults.string(forKey: "CareMyMacSnapshotDir")) }
        guard defaults.bool(forKey: "CareMyMacOpenSettings"),
              let directory = defaults.string(forKey: "CareMyMacSnapshotDir") else { return }
        let warmup = max(2, defaults.double(forKey: "CareMyMacSnapshotWarmup"))

        Task {
            try? await Task.sleep(for: .seconds(max(0.5, warmup - 3)))
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            NSApp.activate()
            delegate.openSettings?()
            try? await Task.sleep(for: .seconds(1.5))
            let settingsWindow = NSApp.windows.first { window in
                window.isVisible && window.identifier?.rawValue.contains(WindowID.main) != true
                    && !String(describing: type(of: window)).contains("StatusBar")
            }
            if let settings = settingsWindow {
                // Tall enough to show every section in one image.
                settings.setContentSize(NSSize(width: settings.frame.width, height: 1000))
                try? await Task.sleep(for: .seconds(0.5))
                render(settings.contentView?.superview, to: "\(directory)/settings.png")
                settings.close()
            }
            renderPanel(delegate: delegate, to: "\(directory)/menubar.png")
            if let item = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("NSStatusBarWindow") }) {
                render(item.contentView, to: "\(directory)/statusitem.png")
            }
        }
    }

    private static func renderPanel(delegate: AppDelegate, to path: String) {
        let root = MenuBarContent()
            .environment(delegate.monitor)
            .environment(delegate.appModel)
            .environment(delegate.updater)
            .background(.windowBackground)
        let host = NSHostingView(rootView: root)
        host.appearance = NSApp.appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSApp.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        render(host, to: path)
    }

    private static func checkForUpdates(delegate: AppDelegate, directory: String?) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            delegate.updater.checkForUpdates()
            for _ in 0..<60 where delegate.updater.availableVersion == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            log("[updates] available=\(delegate.updater.availableVersion ?? "none") lastCheck=\(delegate.updater.lastCheckDate.map { "\($0)" } ?? "never")")
            guard let directory else { return }
            // Let the release notes load.
            try? await Task.sleep(for: .seconds(2))
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            if let alert = NSApp.windows.first(where: { $0.isVisible && String(describing: $0.windowController.map { type(of: $0) }).contains("SUUpdateAlert") }) {
                render(alert.contentView?.superview, to: "\(directory)/update.png")
            }
            renderPanel(delegate: delegate, to: "\(directory)/menubar-update.png")
        }
    }

    private static func render(_ view: NSView?, to path: String) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Toggles the menu bar setting off and back on, and posts a test alert through the notification path.
    private static func checkIntegration(delegate: AppDelegate) {
        func statusItems() -> Int {
            NSApp.windows.filter { String(describing: type(of: $0)).contains("NSStatusBarWindow") && $0.isVisible }.count
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            let stored = UserDefaults.standard.object(forKey: SettingsKey.menuBarEnabled)
            log("[integration] status items before=\(statusItems()) inserted=\(delegate.menuBar.isInserted)")
            UserDefaults.standard.set(false, forKey: SettingsKey.menuBarEnabled)
            try? await Task.sleep(for: .seconds(1.5))
            log("[integration] status items after hiding=\(statusItems()) inserted=\(delegate.menuBar.isInserted)")
            UserDefaults.standard.set(true, forKey: SettingsKey.menuBarEnabled)
            try? await Task.sleep(for: .seconds(1.5))
            log("[integration] status items after showing=\(statusItems()) inserted=\(delegate.menuBar.isInserted)")
            if let stored { UserDefaults.standard.set(stored, forKey: SettingsKey.menuBarEnabled) } else { UserDefaults.standard.removeObject(forKey: SettingsKey.menuBarEnabled) }

            @MainActor func mainWindows() -> String {
                NSApp.windows.filter { $0.identifier?.rawValue.contains(WindowID.main) == true }.map { "visible=\($0.isVisible)" }.joined(separator: ",")
            }
            NSApp.windows.first { $0.identifier?.rawValue.contains(WindowID.main) == true }?.close()
            try? await Task.sleep(for: .seconds(1))
            log("[integration] after closing main: [\(mainWindows())] terminates=\(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))")
            _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            try? await Task.sleep(for: .seconds(1.5))
            log("[integration] after Dock reopen: [\(mainWindows())] isAppVisible=\(delegate.monitor.isAppVisible)")

            await delegate.notifier.refresh()
            log("[integration] notification authorization=\(delegate.notifier.authorization.rawValue)")
            let event = AlertEvent(ruleID: UUID(), date: .now, metric: .cpu, value: 0.9, title: "Test app is using sustained CPU", detail: "Above 80% of one core for at least 2 min.")
            delegate.notifier.post([event])
            try? await Task.sleep(for: .seconds(1))
            log("[integration] posted test alert without crashing")
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func logVisibility(monitor: LiveMonitor) {
        Task {
            var last: Bool?
            while true {
                if last != monitor.isAppVisible {
                    last = monitor.isAppVisible
                    let windows = NSApp.windows.map { "\(type(of: $0))[\($0.identifier?.rawValue ?? "-")] visible=\($0.isVisible) occl=\($0.occlusionState.contains(.visible))" }
                    FileHandle.standardError.write(Data("[visibility] isAppVisible=\(monitor.isAppVisible) interval=\(monitor.interval) windows=\(windows)\n".utf8))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
#endif
