#if DEBUG
import AppKit
import CareMyMacUI

/// Debug-only visual verification: renders pages of the main window to PNG, then quits.
///
///     CareMyMac -CareMyMacSnapshotDir /tmp/shots -CareMyMacSnapshotScreens busy,thisMac,thisMac:cpu \
///             -CareMyMacSnapshotWarmup 30 -CareMyMacAppearance dark
///
/// `thisMac:<tab>` picks a This Mac tab (`all`, `cpu`, `memory`, …); app lists open on their top app.
/// `:wait` waits 12 s before capturing. Warmup lets the live series fill.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(monitor: LiveMonitor, appModel: AppModel) {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "CareMyMacAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        guard let directory = defaults.string(forKey: "CareMyMacSnapshotDir") else { return }
        let requests = (defaults.string(forKey: "CareMyMacSnapshotScreens") ?? Screen.allCases.map(\.rawValue).joined(separator: ","))
            .split(separator: ",")
            .map(String.init)
        let warmup = max(2, defaults.double(forKey: "CareMyMacSnapshotWarmup"))

        Task {
            try? await Task.sleep(for: .seconds(warmup))
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for request in requests {
                let parts = request.split(separator: ":").map(String.init)
                guard let screen = Screen(rawValue: parts[0]) else { continue }
                appModel.screen = screen
                appModel.thisMacTab = parts.dropFirst().lazy.compactMap(ThisMacTab.init(rawValue:)).first ?? .all
                try? await Task.sleep(for: .seconds(parts.contains("wait") ? 12 : 2.5))
                capture(to: "\(directory)/\(request.replacingOccurrences(of: ":", with: "-")).png")
            }
            // terminate(_:) waits on attached sheets; this debug tool just flushes and exits.
            await monitor.flush()
            exit(0)
        }
    }

    /// Main window to `path`; an attached sheet, if any, to `<path>-sheet.png`.
    private static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains(WindowID.main) == true })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        render(window, to: path)
        if let sheet = window.attachedSheet {
            render(sheet, to: path.replacingOccurrences(of: ".png", with: "-sheet.png"))
        }
    }

    private static func render(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
