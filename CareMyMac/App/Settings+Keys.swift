import Foundation
import Observation
import CareMyMacUI

/// UserDefaults keys shared by Settings, the monitor, and the menu bar.
enum SettingsKey {
    static let visibleInterval = "monitor.visibleInterval"
    static let hiddenInterval = "monitor.hiddenInterval"
    static let alertsEnabled = "alerts.enabled"
    static let notificationsEnabled = "alerts.notifications"
    static let menuBarEnabled = "menuBar.enabled"
    static let menuBarMetric = "menuBar.metric"
    static let menuBarStyle = "menuBar.style"
    static let projectsIncludeWithoutPorts = "projects.includeWithoutPorts"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            visibleInterval: 2.0,
            hiddenInterval: 10.0,
            alertsEnabled: true,
            notificationsEnabled: false,
            menuBarEnabled: true,
            menuBarMetric: "cpu",
            menuBarStyle: "figure",
            projectsIncludeWithoutPorts: false,
        ])
    }
}

/// Pushes stored preferences into the monitor.
@MainActor
enum MonitorPreferences {
    static func apply(to monitor: LiveMonitor) {
        let defaults = UserDefaults.standard
        monitor.visibleInterval = max(1, defaults.double(forKey: SettingsKey.visibleInterval))
        monitor.hiddenInterval = max(1, defaults.double(forKey: SettingsKey.hiddenInterval))
        monitor.alertsEnabled = defaults.bool(forKey: SettingsKey.alertsEnabled)
    }
}

/// Value shown by the menu bar extra.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, network, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .network: "Network"
        case .battery: "Battery"
        }
    }

    var resource: Resource {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .gpu: .graphics
        case .network: .network
        case .battery: .battery
        }
    }
}

/// How the menu bar extra draws its metric.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case figure, graph, icon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .figure: "Figure"
        case .graph: "Graph"
        case .icon: "Icon only"
        }
    }
}

/// Whether the menu bar extra is inserted, kept in sync with `SettingsKey.menuBarEnabled`.
///
/// Scenes can't use `@AppStorage` here: it re-evaluates the whole App body on every defaults write,
/// and SwiftUI's own window-state writes then loop. This publishes only real changes of the one key.
@MainActor
@Observable
final class MenuBarVisibility {
    var isInserted: Bool {
        didSet {
            if UserDefaults.standard.bool(forKey: SettingsKey.menuBarEnabled) != isInserted {
                UserDefaults.standard.set(isInserted, forKey: SettingsKey.menuBarEnabled)
            }
        }
    }

    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        isInserted = UserDefaults.standard.object(forKey: SettingsKey.menuBarEnabled) as? Bool ?? true
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let stored = UserDefaults.standard.object(forKey: SettingsKey.menuBarEnabled) as? Bool ?? true
                if stored != self.isInserted { self.isInserted = stored }
            }
        }
    }
}
