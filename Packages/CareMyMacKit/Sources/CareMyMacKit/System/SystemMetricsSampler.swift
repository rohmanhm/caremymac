import Foundation

/// Composes all system samplers into one snapshot per tick. Not thread-safe; own it from a single actor.
public final class SystemMetricsSampler {
    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let disk = DiskIOSampler()
    private let network = NetworkSampler()
    private let gpu = GPUSampler()
    private let battery = BatterySampler()
    private let volumeSampler = VolumeSampler()
    private let accessories = AccessoryBatterySampler()

    public init() {}

    public func sample(now: Date = .now) -> SystemSnapshot {
        SystemSnapshot(
            date: now,
            cpu: cpu.sample(now: now),
            memory: memory.sample(now: now),
            disk: disk.sample(now: now),
            network: network.sample(now: now),
            gpu: gpu.sample(now: now),
            battery: battery.sample(now: now)
        )
    }

    public func volumes() -> [VolumeStats] {
        volumeSampler.sample()
    }

    public func accessoryBatteries() -> [AccessoryBattery] {
        accessories.sample()
    }
}
