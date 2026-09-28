import Darwin
import Foundation
import IOKit

/// Small wrappers over sysctl and the IORegistry shared by the system samplers.
enum SystemProbe {
    // MARK: sysctl

    static func sysctl<T: BitwiseCopyable>(_ name: String, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return value
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let string = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return string.isEmpty ? nil : string
    }

    // MARK: Rates

    /// Growth of a monotonically increasing counter; a counter that went backwards (reset, device removed) yields 0.
    static func delta(from previous: UInt64, to current: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    static func rate(from previous: UInt64, to current: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        return Double(delta(from: previous, to: current)) / elapsed
    }

    // MARK: IORegistry

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Calls `body` for every service matching `className`; stops early when `body` returns false.
    static func forEachService(matching className: String, _ body: (io_object_t) -> Bool) {
        guard let matching = IOServiceMatching(className) else { return }
        var iterator: io_iterator_t = 0
        // IOServiceGetMatchingServices consumes `matching`.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return }
            let keepGoing = body(service)
            IOObjectRelease(service)
            if !keepGoing { return }
        }
    }

    /// Registry strings are either CFString or NUL-terminated CFData depending on the driver.
    static func string(from value: Any?) -> String? {
        if let string = value as? String {
            return string.isEmpty ? nil : string
        }
        if let data = value as? Data {
            let string = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            return string.isEmpty ? nil : string
        }
        return nil
    }

    static func int(from value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    /// IOKit stores some signed values (e.g. battery amperage) as 64-bit two's complement.
    static func int64(from value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    static func uint64(from value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }
}
