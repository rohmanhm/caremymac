import Foundation

/// Display formatting shared by every screen. Unavailable values render as an en dash.
public enum Format {
    public static let unavailable = "–"

    /// "12.88 GB", "779.2 MB", "0 B". Decimal (base-1000) units, matching Finder and Activity Monitor.
    public static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    public static func bytes(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var scaled = value
        var index = 0
        while scaled >= 1000, index < units.count - 1 {
            scaled /= 1000
            index += 1
        }
        if index == 0 { return "\(Int(scaled)) B" }
        let digits = scaled >= 100 ? 1 : 2
        return "\(trimmed(scaled, digits: index <= 1 ? 0 : digits)) \(units[index])"
    }

    /// RAM sizes in binary units, labelled like Activity Monitor: 48 GiB installed shows as "48 GB".
    public static func memory(_ value: UInt64) -> String {
        memory(Double(value))
    }

    public static func memory(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scaled = value
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        if index == 0 { return "\(Int(scaled)) B" }
        let digits = index == 1 ? 0 : scaled >= 100 ? 1 : 2
        return "\(trimmed(scaled, digits: digits)) \(units[index])"
    }

    /// "5 KB/s", "18.4 MB/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var scaled = bytesPerSecond
        var index = 0
        while scaled >= 1000, index < units.count - 1 {
            scaled /= 1000
            index += 1
        }
        let digits = index <= 1 || scaled >= 100 ? 0 : 1
        return "\(trimmed(scaled, digits: digits)) \(units[index])"
    }

    /// Fraction 0...1 (or above, for per-core CPU) as "50.5%".
    public static func percent(_ fraction: Double?, digits: Int = 1) -> String {
        guard let fraction, fraction.isFinite else { return unavailable }
        return "\(fixed(fraction * 100, digits: digits))%"
    }

    /// "1h 17m", "4m", "< 1m".
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return unavailable }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "< 1m" }
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }

    public static func decimal(_ value: Double, digits: Int = 2) -> String {
        fixed(value, digits: digits)
    }

    /// "16,897".
    public static func integer(_ value: some BinaryInteger) -> String {
        Int(clamping: value).formatted()
    }

    private static func fixed(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never))
    }

    /// Fixed digits, then drop trailing zeros ("460.40" → "460.4", "16.00" → "16").
    private static func trimmed(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).grouping(.never))
    }
}
