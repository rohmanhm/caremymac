import Foundation
import IOKit
import IOKit.ps

/// Internal battery state from IOPowerSources plus health details from AppleSmartBattery. Nil on desktops.
public final class BatterySampler {
    public init() {}

    public func sample(now: Date = .now) -> BatteryStats? {
        guard let source = Self.internalBatteryDescription() else { return nil }

        let current = SystemProbe.int(from: source["Current Capacity"]) ?? 0
        let maximum = SystemProbe.int(from: source["Max Capacity"]) ?? 100
        let level = maximum > 0 ? min(max(Double(current) / Double(maximum), 0), 1) : 0
        let isPluggedIn = (source["Power Source State"] as? String) == "AC Power"
        let isCharging = (source["Is Charging"] as? Bool) ?? false
        let isCharged = (source["Is Charged"] as? Bool) ?? false
        let state = Self.state(isPluggedIn: isPluggedIn, isCharging: isCharging, isCharged: isCharged)

        let minutes: Int? = switch state {
        case .discharging: SystemProbe.int(from: source["Time to Empty"])
        case .charging: SystemProbe.int(from: source["Time to Full Charge"])
        case .charged, .notCharging: nil
        }
        let timeRemaining = minutes.flatMap { $0 > 0 ? TimeInterval($0 * 60) : nil }

        var stats = BatteryStats(
            level: level,
            state: state,
            isPluggedIn: isPluggedIn,
            timeRemaining: timeRemaining,
            cycleCount: nil,
            health: nil,
            designCapacity: nil,
            maxCapacity: nil,
            temperatureCelsius: nil,
            powerWatts: nil,
            adapterWatts: nil,
            condition: source["BatteryHealth"] as? String
        )
        Self.addSmartBatteryDetails(to: &stats)
        return stats
    }

    static func state(isPluggedIn: Bool, isCharging: Bool, isCharged: Bool) -> BatteryState {
        if isCharging { return .charging }
        if isCharged { return .charged }
        return isPluggedIn ? .notCharging : .discharging
    }

    /// Maximum capacity relative to design capacity; new cells can exceed design, which reads as full health.
    static func health(maxCapacity: Int?, designCapacity: Int?) -> Double? {
        guard let maxCapacity, let designCapacity, designCapacity > 0, maxCapacity > 0 else { return nil }
        return min(Double(maxCapacity) / Double(designCapacity), 1)
    }

    /// Battery-side power in watts from millivolts × milliamps; positive while discharging.
    static func powerWatts(millivolts: Int64?, milliamps: Int64?) -> Double? {
        guard let millivolts, let milliamps, millivolts > 0 else { return nil }
        return -Double(millivolts) * Double(milliamps) / 1_000_000
    }

    private static func internalBatteryDescription() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description["Type"] as? String) == "InternalBattery",
                  (description["Is Present"] as? Bool) ?? true else { continue }
            return description
        }
        return nil
    }

    private static func addSmartBatteryDetails(to stats: inout BatteryStats) {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return }
        defer { IOObjectRelease(battery) }

        let data = SystemProbe.property(battery, "BatteryData") as? [String: Any]
        func value(_ key: String) -> Any? {
            SystemProbe.property(battery, key) ?? data?[key]
        }

        stats.cycleCount = SystemProbe.int(from: value("CycleCount"))
        let design = SystemProbe.int(from: value("DesignCapacity"))
        let maximum = SystemProbe.int(from: value("AppleRawMaxCapacity")) ?? SystemProbe.int(from: value("NominalChargeCapacity"))
        stats.designCapacity = design
        stats.maxCapacity = maximum
        stats.health = health(maxCapacity: maximum, designCapacity: design)

        if let centi = SystemProbe.int(from: value("Temperature")) ?? SystemProbe.int(from: value("VirtualTemperature")), centi > 0 {
            stats.temperatureCelsius = Double(centi) / 100
        }
        stats.powerWatts = powerWatts(
            millivolts: SystemProbe.int64(from: value("Voltage")),
            milliamps: SystemProbe.int64(from: value("InstantAmperage")) ?? SystemProbe.int64(from: value("Amperage"))
        )
        if stats.isPluggedIn, let adapter = SystemProbe.property(battery, "AdapterDetails") as? [String: Any] {
            stats.adapterWatts = SystemProbe.int(from: adapter["Watts"])
        }
    }
}
