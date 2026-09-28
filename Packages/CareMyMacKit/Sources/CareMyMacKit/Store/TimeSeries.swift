import Foundation

/// Fixed-capacity ring buffer of timestamped values, ordered oldest first.
///
/// Appending past `capacity` overwrites the oldest point. Dates are expected to be
/// non-decreasing (one point per sampler tick); `points(since:)` relies on that order.
public struct TimeSeries<Value> {
    public struct Point {
        public var date: Date
        public var value: Value

        public init(date: Date, value: Value) {
            self.date = date
            self.value = value
        }
    }

    /// Default capacity: 10 minutes at one sample per second.
    public static var defaultCapacity: Int { 600 }

    public let capacity: Int
    private var storage: [Point] = []
    /// Physical index of the oldest point; non-zero only once `storage` is full.
    private var head = 0

    public init(capacity: Int = TimeSeries.defaultCapacity) {
        self.capacity = Swift.max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ value: Value, at date: Date) {
        let point = Point(date: date, value: value)
        if storage.count < capacity {
            storage.append(point)
        } else {
            storage[head] = point
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// All points, oldest first.
    public var points: [Point] {
        guard head != 0 else { return storage }
        var result: [Point] = []
        result.reserveCapacity(storage.count)
        result.append(contentsOf: storage[head...])
        result.append(contentsOf: storage[..<head])
        return result
    }

    /// Points dated at or after `date`, oldest first.
    public func points(since date: Date) -> [Point] {
        // Binary search for the first logical index whose date is >= `date`.
        var low = 0
        var high = storage.count
        while low < high {
            let mid = (low + high) / 2
            if self[logical: mid].date < date { low = mid + 1 } else { high = mid }
        }
        var result: [Point] = []
        result.reserveCapacity(storage.count - low)
        for index in low..<storage.count {
            result.append(self[logical: index])
        }
        return result
    }

    public var first: Point? { storage.isEmpty ? nil : storage[head] }
    public var last: Point? { storage.isEmpty ? nil : self[logical: storage.count - 1] }

    private subscript(logical index: Int) -> Point {
        storage[(head + index) % storage.count]
    }
}

extension TimeSeries where Value: Comparable {
    /// Largest value currently held.
    public var max: Value? { storage.lazy.map(\.value).max() }
}

extension TimeSeries where Value: BinaryFloatingPoint {
    /// Points converted for persistence in a `SavedMoment`, oldest first.
    public var seriesPoints: [SeriesPoint] {
        points.map { SeriesPoint(date: $0.date, value: Double($0.value)) }
    }
}

extension TimeSeries: Sendable where Value: Sendable {}
extension TimeSeries.Point: Sendable where Value: Sendable {}
extension TimeSeries.Point: Equatable where Value: Equatable {}
extension TimeSeries.Point: Hashable where Value: Hashable {}

extension TimeSeries: Equatable where Value: Equatable {
    public static func == (lhs: TimeSeries, rhs: TimeSeries) -> Bool {
        lhs.capacity == rhs.capacity && lhs.points == rhs.points
    }
}
