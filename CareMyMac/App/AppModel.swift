import Foundation
import CareMyMacUI
import CareMyMacKit
import Observation

/// Every source in the sidebar. Overview first, then the app lists and Developer; the rest are pages.
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case overview
    case apps, background, developer
    case thisMac, storage, timeline
    case alerts, markers
    case cleanup, uninstaller, optimize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .apps: "Apps"
        case .background: "Background"
        case .developer: "Developer"
        case .thisMac: "This Mac"
        case .storage: "Storage"
        case .timeline: "Timeline"
        case .alerts: "Alerts"
        case .markers: "Markers"
        case .cleanup: "Cleanup"
        case .uninstaller: "Uninstaller"
        case .optimize: "Optimize"
        }
    }

    /// This Mac takes the symbol of the actual model.
    func symbol(for machine: MachineInfo) -> String {
        switch self {
        case .overview: "waveform.path.ecg"
        case .apps: "square.grid.2x2"
        case .background: "square.3.layers.3d.down.right"
        case .developer: "terminal"
        case .thisMac: machine.symbol
        case .storage: "internaldrive"
        case .timeline: "chart.xyaxis.line"
        case .alerts: "bell"
        case .markers: "flag"
        case .cleanup: "bubbles.and.sparkles"
        case .uninstaller: "trash"
        case .optimize: "wrench.and.screwdriver"
        }
    }

    /// Which apps an app-list source shows; nil for pages.
    var appFilter: AppFilter? {
        switch self {
        case .apps: .applications
        case .background: .background
        default: nil
        }
    }

    static let lists: [Screen] = [.apps, .background, .developer]
    static let mac: [Screen] = [.thisMac, .storage, .timeline]
    static let watch: [Screen] = [.alerts, .markers]
    static let care: [Screen] = [.cleanup, .uninstaller, .optimize]
}

enum AppFilter {
    case applications, background

    func includes(_ app: AppActivity) -> Bool {
        switch self {
        case .applications: app.kind == .application
        case .background: app.kind != .application
        }
    }

    /// Busy: at least 1% of a core, or 1 MB/s of disk traffic, right now.
    static func isBusy(_ app: AppActivity) -> Bool {
        app.cpu >= 0.01 || app.diskReadBytesPerSecond + app.diskWriteBytesPerSecond >= 1_000_000
    }
}

/// Order of the app list.
enum AppSort: String, CaseIterable, Identifiable {
    case cpu, memory, disk, name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .name: "Name"
        }
    }

    /// Largest first, except names (A–Z). Ties fall back to name so rows don't shuffle between ticks.
    func sorted(_ apps: [AppActivity]) -> [AppActivity] {
        apps.sorted { lhs, rhs in
            let key: (Double, Double)? = switch self {
            case .cpu: (lhs.cpu, rhs.cpu)
            case .memory: (Double(lhs.memory), Double(rhs.memory))
            case .disk: (lhs.diskReadBytesPerSecond + lhs.diskWriteBytesPerSecond, rhs.diskReadBytesPerSecond + rhs.diskWriteBytesPerSecond)
            case .name: nil
            }
            if let key, key.0 != key.1 { return key.0 > key.1 }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Tabs of the This Mac page: every resource on one clock, then one page per resource.
enum ThisMacTab: String, CaseIterable, Identifiable, Hashable {
    case all, cpu, memory, disk, network, graphics, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .graphics: "Graphics"
        case .battery: "Battery"
        }
    }
}

/// Navigation state for the main window.
@MainActor
@Observable
final class AppModel {
    var screen: Screen = .overview
    var thisMacTab: ThisMacTab = .all
    /// Selected app in the app list. Kept while the app is gone so the detail can say it quit.
    var selectedAppID: String?
    var appSort: AppSort = .cpu
    /// Apps list shows only busy apps.
    var busyOnly = false
    /// Marker selected on the Markers page.
    var selectedMarkerID: UUID?

    /// Opens the app list that contains `app` and selects it.
    func show(_ app: AppActivity) {
        if screen.appFilter?.includes(app) != true {
            screen = app.kind == .application ? .apps : .background
        }
        // Busy only would hide an idle app.
        if screen == .apps, !AppFilter.isBusy(app) { busyOnly = false }
        selectedAppID = app.id
    }

    /// The Apps list sorted by a resource ("Show All" under a resource's top apps).
    /// Memory is held by idle apps too, so it lists every app instead of the busy ones.
    func showApps(sortedBy sort: AppSort) {
        appSort = sort
        busyOnly = sort != .memory
        screen = .apps
    }
}
