import Darwin
import Foundation

/// Samples per-core CPU ticks and turns deltas into user/system shares.
public final class CPUSampler {
    /// Raw cumulative ticks for one logical core.
    struct CoreTicks: Equatable {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private let host = mach_host_self()
    private var previous: [CoreTicks] = []
    private let performanceCoreCount: Int?
    private let efficiencyCoreCount: Int?

    public init() {
        performanceCoreCount = SystemProbe.sysctl("hw.perflevel0.logicalcpu", initial: Int32(0)).map(Int.init)
        efficiencyCoreCount = SystemProbe.sysctl("hw.perflevel1.logicalcpu", initial: Int32(0)).map(Int.init)
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    public func sample(now: Date = .now) -> CPUStats {
        let current = readTicks() ?? []
        let (user, system, cores) = Self.shares(previous: previous, current: current)
        previous = current
        return CPUStats(
            user: user,
            system: system,
            cores: cores,
            performanceCoreCount: performanceCoreCount,
            efficiencyCoreCount: efficiencyCoreCount,
            loadAverage: Self.loadAverage()
        )
    }

    /// Converts two tick snapshots into machine-wide and per-core shares.
    /// Ticks are 32-bit and wrap, so deltas use wrapping subtraction. A changed core count yields zeros.
    static func shares(previous: [CoreTicks], current: [CoreTicks]) -> (user: Double, system: Double, cores: [CPUStats.Core]) {
        guard !previous.isEmpty, previous.count == current.count else {
            return (0, 0, current.map { _ in CPUStats.Core(user: 0, system: 0) })
        }
        var userSum: UInt64 = 0
        var systemSum: UInt64 = 0
        var totalSum: UInt64 = 0
        var cores: [CPUStats.Core] = []
        cores.reserveCapacity(current.count)
        for (old, new) in zip(previous, current) {
            let user = UInt64(new.user &- old.user) + UInt64(new.nice &- old.nice)
            let system = UInt64(new.system &- old.system)
            let total = user + system + UInt64(new.idle &- old.idle)
            userSum += user
            systemSum += system
            totalSum += total
            if total == 0 {
                cores.append(CPUStats.Core(user: 0, system: 0))
            } else {
                cores.append(CPUStats.Core(user: Double(user) / Double(total), system: Double(system) / Double(total)))
            }
        }
        guard totalSum > 0 else { return (0, 0, cores) }
        return (Double(userSum) / Double(totalSum), Double(systemSum) / Double(totalSum), cores)
    }

    private func readTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }
        let stride = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(cpuCount) * stride else { return nil }
        return (0..<Int(cpuCount)).map { index in
            let base = index * stride
            return CoreTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    private static func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        let count = getloadavg(&values, 3)
        return count > 0 ? Array(values.prefix(Int(count))) : []
    }
}
