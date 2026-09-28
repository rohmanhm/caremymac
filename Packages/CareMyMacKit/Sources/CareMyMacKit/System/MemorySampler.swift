import Darwin
import Foundation

/// Samples VM statistics the way Activity Monitor presents them.
public final class MemorySampler {
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let physical: UInt64

    public init() {
        var size: vm_size_t = 0
        pageSize = host_page_size(host, &size) == KERN_SUCCESS && size > 0 ? UInt64(size) : 16_384
        physical = SystemProbe.sysctl("hw.memsize", initial: UInt64(0)) ?? 0
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    public func sample(now: Date = .now) -> MemoryStats {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            var empty = MemoryStats.zero
            empty.physical = physical
            return empty
        }

        let page = pageSize
        let `internal` = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let swap = SystemProbe.sysctl("vm.swapusage", initial: xsw_usage())

        return MemoryStats(
            physical: physical,
            app: (`internal` > purgeable ? `internal` - purgeable : 0) * page,
            active: UInt64(stats.active_count) * page,
            inactive: UInt64(stats.inactive_count) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cachedFiles: (UInt64(stats.external_page_count) + purgeable) * page,
            free: UInt64(stats.free_count) * page,
            swapUsed: swap?.xsu_used ?? 0,
            swapTotal: swap?.xsu_total ?? 0,
            pressure: Self.pressure(level: SystemProbe.sysctl("kern.memorystatus_vm_pressure_level", initial: Int32(0)))
        )
    }

    /// Maps kern.memorystatus_vm_pressure_level (1 normal, 2 warning, 4 critical).
    static func pressure(level: Int32?) -> MemoryPressure {
        switch level {
        case 2: .warning
        case 4: .critical
        default: .normal
        }
    }
}
