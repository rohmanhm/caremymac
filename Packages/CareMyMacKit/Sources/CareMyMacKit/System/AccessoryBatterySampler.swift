import Foundation
import IOKit

/// Battery level of a connected peripheral (Magic Mouse, Keyboard, Trackpad…).
public struct AccessoryBattery: Sendable, Hashable, Codable, Identifiable {
    /// Serial number or Bluetooth address when available.
    public var id: String
    public var name: String
    public var level: Double
    /// Nil when the device doesn't report charging state.
    public var isCharging: Bool?

    public init(id: String, name: String, level: Double, isCharging: Bool?) {
        self.id = id
        self.name = name
        self.level = level
        self.isCharging = isCharging
    }
}

/// Finds IORegistry services publishing "BatteryPercent" (HID accessories).
/// AirPods and other audio devices aren't in the IORegistry and don't appear here.
public final class AccessoryBatterySampler {
    public init() {}

    public func sample() -> [AccessoryBattery] {
        let matching: [String: Any] = [
            kIOProviderClassKey as String: "IOService",
            "IOPropertyExistsMatch": ["BatteryPercent"],
        ]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var byID: [String: AccessoryBattery] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let percent = SystemProbe.int(from: SystemProbe.property(service, "BatteryPercent")) else { continue }
            let name = SystemProbe.string(from: SystemProbe.property(service, "Product")) ?? "Accessory"
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            let id = SystemProbe.string(from: SystemProbe.property(service, "SerialNumber"))
                ?? SystemProbe.string(from: SystemProbe.property(service, "DeviceAddress"))
                ?? "\(name)-\(entryID)"
            // The same device is often published by several drivers; keep the first.
            guard byID[id] == nil else { continue }
            byID[id] = AccessoryBattery(
                id: id,
                name: name,
                level: min(max(Double(percent) / 100, 0), 1),
                isCharging: SystemProbe.property(service, "Charging") as? Bool
            )
        }
        return byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
