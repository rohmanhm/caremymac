import Foundation

/// SQLite persistence for minute history, saved moments, alert rules and alert events.
///
/// Thread-confined and deliberately not `Sendable`: create, use and release an instance on a
/// single thread or inside a single actor. The connection is opened without sqlite's internal
/// mutex. File-backed stores use WAL journaling.
public final class HistoryStore {
    /// How long minute records and alert events are kept.
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    /// Oldest moments are deleted when saving beyond this count.
    public static let maxMoments = 100
    static let schemaVersion: Int32 = 1

    /// `~/Library/Application Support/CareMyMac/history.sqlite`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "CareMyMac", "history.sqlite")
    }

    private let connection: SQLiteConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Opens (creating directories and file if needed) and migrates the database at `url`.
    public convenience init(url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw StoreError.fileSystem(error.localizedDescription)
        }
        try self.init(path: url.path(percentEncoded: false))
    }

    /// A private, empty in-memory database.
    public static func inMemory() throws -> HistoryStore {
        try HistoryStore(path: ":memory:")
    }

    private init(path: String) throws {
        connection = try SQLiteConnection(path: path)
        try connection.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA busy_timeout = 5000;
            """)
        try migrate()
    }

    // MARK: - Schema

    func userVersion() throws -> Int32 {
        try connection.withStatement("PRAGMA user_version") { statement in
            try statement.step() ? Int32(truncatingIfNeeded: statement.int64(0)) : 0
        }
    }

    private func migrate() throws {
        var version = try userVersion()
        guard version <= Self.schemaVersion else { throw StoreError.unsupportedSchemaVersion(version) }
        while version < Self.schemaVersion {
            let next = version + 1
            try connection.transaction {
                try applyMigration(to: next)
                try connection.execute("PRAGMA user_version = \(next)")
            }
            version = next
        }
    }

    private func applyMigration(to version: Int32) throws {
        switch version {
        case 1:
            try connection.execute("""
                CREATE TABLE records (
                    minute INTEGER PRIMARY KEY,
                    cpu_average REAL NOT NULL,
                    cpu_peak REAL NOT NULL,
                    cpu_user REAL NOT NULL,
                    cpu_system REAL NOT NULL,
                    memory_used INTEGER NOT NULL,
                    memory_physical INTEGER NOT NULL,
                    memory_pressure TEXT NOT NULL,
                    swap_used INTEGER NOT NULL,
                    disk_read REAL NOT NULL,
                    disk_write REAL NOT NULL,
                    net_in REAL NOT NULL,
                    net_out REAL NOT NULL,
                    gpu_utilization REAL,
                    battery_level REAL,
                    battery_plugged_in INTEGER,
                    top_apps BLOB NOT NULL,
                    sample_count INTEGER NOT NULL
                );
                CREATE TABLE moments (id TEXT PRIMARY KEY, date REAL NOT NULL, json BLOB NOT NULL);
                CREATE INDEX moments_date ON moments(date);
                CREATE TABLE alert_rules (id TEXT PRIMARY KEY, position INTEGER NOT NULL, json BLOB NOT NULL);
                CREATE TABLE alert_events (
                    id TEXT PRIMARY KEY,
                    date REAL NOT NULL,
                    rule_id TEXT NOT NULL,
                    is_read INTEGER NOT NULL DEFAULT 0,
                    json BLOB NOT NULL
                );
                CREATE INDEX alert_events_date ON alert_events(date);
                """)
            for rule in AlertRule.defaults {
                try saveAlertRule(rule)
            }
        default:
            throw StoreError.unsupportedSchemaVersion(version)
        }
    }

    // MARK: - Records

    /// Inserts or replaces the record for `record.date`'s minute.
    public func insert(_ record: HistoryRecord) throws {
        let topApps = try encode(record.topApps)
        try connection.withStatement("""
            INSERT OR REPLACE INTO records (minute, cpu_average, cpu_peak, cpu_user, cpu_system, memory_used,
                memory_physical, memory_pressure, swap_used, disk_read, disk_write, net_in, net_out,
                gpu_utilization, battery_level, battery_plugged_in, top_apps, sample_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            try statement.bind(Self.minuteKey(record.date), at: 1)
            try statement.bind(record.cpuAverage, at: 2)
            try statement.bind(record.cpuPeak, at: 3)
            try statement.bind(record.cpuUser, at: 4)
            try statement.bind(record.cpuSystem, at: 5)
            try statement.bind(Int64(clamping: record.memoryUsed), at: 6)
            try statement.bind(Int64(clamping: record.memoryPhysical), at: 7)
            try statement.bind(record.memoryPressure.rawValue, at: 8)
            try statement.bind(Int64(clamping: record.swapUsed), at: 9)
            try statement.bind(record.diskReadBytesPerSecond, at: 10)
            try statement.bind(record.diskWriteBytesPerSecond, at: 11)
            try statement.bind(record.networkInBytesPerSecond, at: 12)
            try statement.bind(record.networkOutBytesPerSecond, at: 13)
            try statement.bind(record.gpuUtilization, at: 14)
            try statement.bind(record.batteryLevel, at: 15)
            try statement.bind(record.batteryPluggedIn.map { $0 ? Int64(1) : 0 }, at: 16)
            try statement.bind(topApps, at: 17)
            try statement.bind(Int64(record.sampleCount), at: 18)
            try statement.run()
        }
    }

    /// Records whose minute start lies in `from...to`, oldest first.
    public func records(from: Date, to: Date) throws -> [HistoryRecord] {
        try connection.withStatement("""
            SELECT minute, cpu_average, cpu_peak, cpu_user, cpu_system, memory_used, memory_physical,
                memory_pressure, swap_used, disk_read, disk_write, net_in, net_out, gpu_utilization,
                battery_level, battery_plugged_in, top_apps, sample_count
            FROM records WHERE minute >= ? AND minute <= ? ORDER BY minute
            """) { statement in
            try statement.bind(Self.minuteKey(from, roundingUp: true), at: 1)
            try statement.bind(Self.minuteKey(to), at: 2)
            var records: [HistoryRecord] = []
            while try statement.step() {
                records.append(try decodeRecord(statement))
            }
            return records
        }
    }

    public func latestRecordDate() throws -> Date? {
        try connection.withStatement("SELECT MAX(minute) FROM records") { statement in
            guard try statement.step(), !statement.isNull(0) else { return nil }
            return Date(timeIntervalSince1970: Double(statement.int64(0)))
        }
    }

    public func recordCount() throws -> Int {
        try count("SELECT COUNT(*) FROM records")
    }

    /// Deletes records whose minute started before `date`. Returns the number deleted.
    @discardableResult
    public func prune(olderThan date: Date) throws -> Int {
        try connection.withStatement("DELETE FROM records WHERE minute < ?") { statement in
            try statement.bind(Self.minuteKey(date, roundingUp: true), at: 1)
            try statement.run()
            return connection.changes
        }
    }

    /// Applies the 30-day retention to records and alert events.
    public func pruneExpired(now: Date = .now) throws {
        let cutoff = now.addingTimeInterval(-Self.retention)
        try connection.transaction {
            try prune(olderThan: cutoff)
            try deleteEvents(before: cutoff)
        }
    }

    private func decodeRecord(_ statement: SQLiteStatement) throws -> HistoryRecord {
        guard let pressureText = statement.text(7), let pressure = MemoryPressure(rawValue: pressureText) else {
            throw StoreError.codec("unknown memory pressure \(statement.text(7) ?? "NULL")")
        }
        return HistoryRecord(
            date: Date(timeIntervalSince1970: Double(statement.int64(0))),
            cpuAverage: statement.double(1),
            cpuPeak: statement.double(2),
            cpuUser: statement.double(3),
            cpuSystem: statement.double(4),
            memoryUsed: UInt64(clamping: statement.int64(5)),
            memoryPhysical: UInt64(clamping: statement.int64(6)),
            memoryPressure: pressure,
            swapUsed: UInt64(clamping: statement.int64(8)),
            diskReadBytesPerSecond: statement.double(9),
            diskWriteBytesPerSecond: statement.double(10),
            networkInBytesPerSecond: statement.double(11),
            networkOutBytesPerSecond: statement.double(12),
            gpuUtilization: statement.optionalDouble(13),
            batteryLevel: statement.optionalDouble(14),
            batteryPluggedIn: statement.isNull(15) ? nil : statement.int64(15) != 0,
            topApps: try decode([AppSummary].self, from: statement.blob(16)),
            sampleCount: Int(statement.int64(17))
        )
    }

    /// Whole seconds since 1970 of the minute containing `date` (or the next minute when rounding up
    /// a date that is not a minute start).
    private static func minuteKey(_ date: Date, roundingUp: Bool = false) -> Int64 {
        let minutes = date.timeIntervalSince1970 / 60
        let rounded = roundingUp ? minutes.rounded(.up) : minutes.rounded(.down)
        guard rounded.isFinite, abs(rounded) < 1e15 else { return rounded < 0 ? .min : .max }
        return Int64(rounded) * 60
    }

    // MARK: - Moments

    /// Inserts or replaces a moment, then deletes the oldest beyond `maxMoments`.
    public func save(_ moment: SavedMoment) throws {
        let json = try encode(moment)
        try connection.transaction {
            try connection.withStatement("INSERT OR REPLACE INTO moments (id, date, json) VALUES (?, ?, ?)") { statement in
                try statement.bind(moment.id.uuidString, at: 1)
                try statement.bind(moment.date.timeIntervalSince1970, at: 2)
                try statement.bind(json, at: 3)
                try statement.run()
            }
            try connection.withStatement("""
                DELETE FROM moments WHERE id NOT IN (SELECT id FROM moments ORDER BY date DESC, rowid DESC LIMIT ?)
                """) { statement in
                try statement.bind(Int64(Self.maxMoments), at: 1)
                try statement.run()
            }
        }
    }

    /// Replaces an existing moment; throws `StoreError.notFound` if it was deleted.
    public func updateMoment(_ moment: SavedMoment) throws {
        let json = try encode(moment)
        try connection.withStatement("UPDATE moments SET date = ?, json = ? WHERE id = ?") { statement in
            try statement.bind(moment.date.timeIntervalSince1970, at: 1)
            try statement.bind(json, at: 2)
            try statement.bind(moment.id.uuidString, at: 3)
            try statement.run()
        }
        if connection.changes == 0 { throw StoreError.notFound }
    }

    /// All moments, newest first.
    public func moments() throws -> [SavedMoment] {
        try connection.withStatement("SELECT json FROM moments ORDER BY date DESC, rowid DESC") { statement in
            var moments: [SavedMoment] = []
            while try statement.step() {
                moments.append(try decode(SavedMoment.self, from: statement.blob(0)))
            }
            return moments
        }
    }

    public func deleteMoment(id: UUID) throws {
        try connection.withStatement("DELETE FROM moments WHERE id = ?") { statement in
            try statement.bind(id.uuidString, at: 1)
            try statement.run()
        }
    }

    // MARK: - Alert rules

    /// Rules in the order they were first saved.
    public func alertRules() throws -> [AlertRule] {
        try connection.withStatement("SELECT json FROM alert_rules ORDER BY position") { statement in
            var rules: [AlertRule] = []
            while try statement.step() {
                rules.append(try decode(AlertRule.self, from: statement.blob(0)))
            }
            return rules
        }
    }

    /// Inserts a new rule at the end, or updates an existing one in place.
    public func saveAlertRule(_ rule: AlertRule) throws {
        let json = try encode(rule)
        try connection.withStatement("""
            INSERT INTO alert_rules (id, position, json)
            VALUES (?, (SELECT COALESCE(MAX(position), -1) + 1 FROM alert_rules), ?)
            ON CONFLICT(id) DO UPDATE SET json = excluded.json
            """) { statement in
            try statement.bind(rule.id.uuidString, at: 1)
            try statement.bind(json, at: 2)
            try statement.run()
        }
    }

    public func deleteAlertRule(id: UUID) throws {
        try connection.withStatement("DELETE FROM alert_rules WHERE id = ?") { statement in
            try statement.bind(id.uuidString, at: 1)
            try statement.run()
        }
    }

    // MARK: - Alert events

    public func append(_ event: AlertEvent) throws {
        let json = try encode(event)
        try connection.withStatement("INSERT INTO alert_events (id, date, rule_id, is_read, json) VALUES (?, ?, ?, ?, ?)") { statement in
            try statement.bind(event.id.uuidString, at: 1)
            try statement.bind(event.date.timeIntervalSince1970, at: 2)
            try statement.bind(event.ruleID.uuidString, at: 3)
            try statement.bind(Int64(event.isRead ? 1 : 0), at: 4)
            try statement.bind(json, at: 5)
            try statement.run()
        }
    }

    /// Newest first.
    public func events(limit: Int) throws -> [AlertEvent] {
        try connection.withStatement("SELECT json, is_read FROM alert_events ORDER BY date DESC, rowid DESC LIMIT ?") { statement in
            try statement.bind(Int64(max(0, limit)), at: 1)
            var events: [AlertEvent] = []
            while try statement.step() {
                var event = try decode(AlertEvent.self, from: statement.blob(0))
                event.isRead = statement.int64(1) != 0
                events.append(event)
            }
            return events
        }
    }

    public func markAllRead() throws {
        try connection.execute("UPDATE alert_events SET is_read = 1 WHERE is_read = 0")
    }

    public func unreadCount() throws -> Int {
        try count("SELECT COUNT(*) FROM alert_events WHERE is_read = 0")
    }

    @discardableResult
    public func deleteEvents(before date: Date) throws -> Int {
        try connection.withStatement("DELETE FROM alert_events WHERE date < ?") { statement in
            try statement.bind(date.timeIntervalSince1970, at: 1)
            try statement.run()
            return connection.changes
        }
    }

    public func deleteEvent(id: UUID) throws {
        try connection.withStatement("DELETE FROM alert_events WHERE id = ?") { statement in
            try statement.bind(id.uuidString, at: 1)
            try statement.run()
        }
    }

    // MARK: - Helpers

    private func count(_ sql: String) throws -> Int {
        try connection.withStatement(sql) { statement in
            try statement.step() ? Int(statement.int64(0)) : 0
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw StoreError.codec(String(describing: error))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw StoreError.codec(String(describing: error))
        }
    }
}
