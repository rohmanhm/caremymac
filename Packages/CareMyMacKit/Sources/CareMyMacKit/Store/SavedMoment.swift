import Foundation

public struct SeriesPoint: Codable, Sendable, Hashable {
    public var date: Date
    public var value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// A user-saved snapshot of the machine with the 1 s series surrounding it
/// (the app captures 2 min before and 30 s after `date`).
public struct SavedMoment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var title: String
    public var note: String
    public var snapshot: SystemSnapshot
    public var topApps: [AppSummary]
    /// CPU total, 0...1.
    public var cpuSeries: [SeriesPoint]
    /// Memory used, bytes.
    public var memorySeries: [SeriesPoint]
    public var networkInSeries: [SeriesPoint]
    public var networkOutSeries: [SeriesPoint]
    public var diskReadSeries: [SeriesPoint]
    public var diskWriteSeries: [SeriesPoint]
    /// GPU utilization, 0...1; empty when unavailable.
    public var gpuSeries: [SeriesPoint]

    public init(id: UUID = UUID(), date: Date, title: String, note: String = "", snapshot: SystemSnapshot, topApps: [AppSummary] = [], cpuSeries: [SeriesPoint] = [], memorySeries: [SeriesPoint] = [], networkInSeries: [SeriesPoint] = [], networkOutSeries: [SeriesPoint] = [], diskReadSeries: [SeriesPoint] = [], diskWriteSeries: [SeriesPoint] = [], gpuSeries: [SeriesPoint] = []) {
        self.id = id
        self.date = date
        self.title = title
        self.note = note
        self.snapshot = snapshot
        self.topApps = topApps
        self.cpuSeries = cpuSeries
        self.memorySeries = memorySeries
        self.networkInSeries = networkInSeries
        self.networkOutSeries = networkOutSeries
        self.diskReadSeries = diskReadSeries
        self.diskWriteSeries = diskWriteSeries
        self.gpuSeries = gpuSeries
    }
}
