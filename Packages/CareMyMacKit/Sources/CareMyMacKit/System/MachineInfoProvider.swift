import Foundation
import IOKit
import SystemConfiguration

public enum MachineInfoProvider {
    public static func current() -> MachineInfo {
        let processInfo = ProcessInfo.processInfo
        let version = processInfo.operatingSystemVersion
        let osVersion = version.patchVersion > 0
            ? "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "macOS \(version.majorVersion).\(version.minorVersion)"
        let coreCount = SystemProbe.sysctl("hw.logicalcpu", initial: Int32(0)).map(Int.init) ?? processInfo.processorCount

        return MachineInfo(
            modelName: productName() ?? SystemProbe.sysctlString("hw.model") ?? "Mac",
            chipName: SystemProbe.sysctlString("machdep.cpu.brand_string") ?? "Unknown",
            coreCount: coreCount,
            physicalMemory: SystemProbe.sysctl("hw.memsize", initial: UInt64(0)) ?? processInfo.physicalMemory,
            osVersion: osVersion,
            hostName: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? processInfo.hostName
        )
    }

    /// Marketing name, e.g. "MacBook Pro (14-inch, 2024)"; only published on Apple Silicon.
    private static func productName() -> String? {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard product != 0 else { return nil }
        defer { IOObjectRelease(product) }
        return SystemProbe.string(from: SystemProbe.property(product, "product-name"))
    }
}
