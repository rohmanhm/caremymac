import Foundation
import IOKit
import Metal

/// Reads IOAccelerator performance statistics. Returns nil when no accelerator exposes them.
public final class GPUSampler {
    private var cachedName: String?
    private var cachedCoreCount: Int?

    public init() {}

    public func sample(now: Date = .now) -> GPUStats? {
        var result: GPUStats?
        SystemProbe.forEachService(matching: "IOAccelerator") { accelerator in
            guard let statistics = SystemProbe.property(accelerator, "PerformanceStatistics") as? [String: Any] else { return true }
            if cachedName == nil {
                cachedName = SystemProbe.string(from: SystemProbe.property(accelerator, "model"))
                    ?? MTLCreateSystemDefaultDevice()?.name
                cachedCoreCount = SystemProbe.int(from: SystemProbe.property(accelerator, "gpu-core-count"))
            }
            result = GPUStats(
                name: cachedName ?? "GPU",
                coreCount: cachedCoreCount,
                utilization: Self.percent(statistics["Device Utilization %"]),
                rendererUtilization: Self.percent(statistics["Renderer Utilization %"]),
                tilerUtilization: Self.percent(statistics["Tiler Utilization %"]),
                memoryInUse: SystemProbe.uint64(from: statistics["In use system memory"])
            )
            return false
        }
        return result
    }

    /// Converts a 0...100 counter into a clamped 0...1 fraction.
    static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return min(max(number.doubleValue / 100, 0), 1)
    }
}
