import Foundation
import CareMyMacUI
import CareMyMacKit
import Observation

/// Every source in the sidebar. The first three are app lists; the rest are pages.
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case busy, allApps, background, developer
    case thisMac, storage, timeline
    case alerts, markers
    case cleanup, uninstaller, optimize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .busy: "Busy Now"
        case .allApps: "All Apps"
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

    var symbol: String {
        switch self {
        case .busy: "bolt"
        case .allApps: "square.grid.2x2"
        case .background: "gearshape.2"
        case .developer: "terminal"
        case .thisMac: "laptopcomputer"
        case .storage: Resource.storage.symbol
        case .timeline: "clock"
        case .alerts: "bell"
        case .markers: "flag"
        case .cleanup: "sparkles"
        case .uninstaller: "xmark.bin"
        case .optimize: "gauge.with.dots.needle.67percent"
        }
    }

    /// Which apps an app-list source shows; nil for pages.
    var appFilter: AppFilter? {
        switch self {
        case .busy: .busy
        case .allApps: .applications
        case .background: .background
        default: nil
        }
    }

    static let apps: [Screen] = [.busy, .allApps, .background, .developer]
    static let mac: [Screen] = [.thisMac, .storage, .timeline]
    static let watch: [Screen] = [.alerts, .markers]
    static let care: [Screen] = [.cleanup, .uninstaller, .optimize]
}

enum AppFilter {
    case busy, applications, background

    /// Busy: at least 1% of a core, or 1 MB/s of disk traffic, right now.
    func includes(_ app: AppActivity) -> Bool {
        switch self {
        case .busy: app.cpu >= 0.01 || app.diskReadBytesPerSecond + app.diskWriteBytesPerSecond >= 1_000_000
        case .applications: app.kind == .application
        case .background: app.kind != .application
        }
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
    var screen: Screen = .busy
    var thisMacTab: ThisMacTab = .all
    /// Selected app in the app list. Kept while the app is gone so the detail can say it quit.
    var selectedAppID: String?
    var appSort: AppSort = .cpu
    /// Marker selected on the Markers page.
    var selectedMarkerID: UUID?

    /// Opens the app list that contains `app` and selects it.
    func show(_ app: AppActivity) {
        if let filter = screen.appFilter, filter.includes(app) {
            // Already listed where the user is.
        } else {
            screen = app.kind == .application ? .allApps : .background
        }
        selectedAppID = app.id
    }

    /// The app list for a resource, sorted by it ("Show All" under a resource's top apps).
    /// Memory is held by idle apps too, so it opens every app instead of the busy ones.
    func showApps(sortedBy sort: AppSort) {
        appSort = sort
        screen = sort == .memory ? .allApps : .busy
    }
}
