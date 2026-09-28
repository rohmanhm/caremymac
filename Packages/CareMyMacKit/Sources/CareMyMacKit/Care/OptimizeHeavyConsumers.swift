import Foundation

/// Apps using a lot of CPU or memory right now.
public enum HeavyConsumers {
    /// Half of one core (CPU is a fraction of one core; 1.0 = a full core).
    public static let cpuThreshold = 0.5
    /// 2 GB of memory (binary, as Activity Monitor counts it).
    public static let memoryThreshold: UInt64 = 2 * 1024 * 1024 * 1024

    public static func isHeavy(_ app: AppActivity) -> Bool {
        app.cpu >= cpuThreshold || app.memory >= memoryThreshold
    }

    /// Heavy apps, busiest CPU first, then largest memory.
    public static func filter(_ apps: [AppActivity]) -> [AppActivity] {
        apps.filter(isHeavy).sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
    }
}
