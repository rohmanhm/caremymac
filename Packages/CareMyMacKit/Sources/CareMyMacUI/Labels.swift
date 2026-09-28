import Foundation
import CareMyMacKit

public extension MemoryPressure {
    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

public extension BatteryState {
    var label: String {
        switch self {
        case .charging: "Charging"
        case .discharging: "On battery"
        case .charged: "Charged"
        case .notCharging: "Not charging"
        }
    }
}

public extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Throttling"
        @unknown default: "Unknown"
        }
    }
}

public extension AppKind {
    var label: String {
        switch self {
        case .application: "Application"
        case .background: "Background"
        case .system: "System"
        }
    }
}

public extension NetworkInterfaceKind {
    var label: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .cellular: "Cellular"
        case .vpn: "VPN / tunnel"
        case .bridge: "Bridge"
        case .loopback: "Loopback"
        case .other: "Other"
        }
    }
}

/// Live chart window shared by every page.
public enum LiveRange: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public var shortLabel: String {
        switch self {
        case .oneMinute: "1 Min"
        case .fiveMinutes: "5 Min"
        case .tenMinutes: "10 Min"
        }
    }

    public var longLabel: String {
        switch self {
        case .oneMinute: "Last minute"
        case .fiveMinutes: "Last 5 minutes"
        case .tenMinutes: "Last 10 minutes"
        }
    }
}

public extension Format {
    /// "1 process", "57 processes".
    static func processes(_ count: Int) -> String {
        count == 1 ? "1 process" : "\(integer(count)) processes"
    }
}
