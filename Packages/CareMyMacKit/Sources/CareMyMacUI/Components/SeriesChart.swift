import Charts
import CareMyMacKit
import Observation
import SwiftUI

public typealias ChartPoint = TimeSeries<Double>.Point

/// The hovered moment, shared by every chart on a page. Only cursor overlays and value labels read it,
/// so hovering never re-renders chart marks.
@MainActor
@Observable
public final class ScrubState {
    public var date: Date?
    public init() {}
}

public enum SeriesMath {
    /// Nearest point's value to `date`, or nil when no point lies within `tolerance`.
    public static func value(in points: [ChartPoint], at date: Date, tolerance: TimeInterval = 15) -> Double? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < date { low = mid + 1 } else { high = mid }
        }
        var best = points[low]
        if low > 0, abs(points[low - 1].date.timeIntervalSince(date)) < abs(best.date.timeIntervalSince(date)) {
            best = points[low - 1]
        }
        return abs(best.date.timeIntervalSince(date)) <= tolerance ? best.value : nil
    }

    public static func average(_ points: [ChartPoint]) -> Double? {
        points.isEmpty ? nil : points.reduce(0) { $0 + $1.value } / Double(points.count)
    }

    public static func peak(_ points: [ChartPoint]) -> Double? {
        points.lazy.map(\.value).max()
    }

    /// Rounds up to 1, 2 or 5 × 10ⁿ so rate axes land on readable ticks.
    public static func niceCeiling(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let exponent = floor(log10(value))
        let magnitude = pow(10, exponent)
        let fraction = value / magnitude
        let nice: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10
        return nice * magnitude
    }
}

/// Area + line chart on a fixed time domain, with an optional dashed secondary series and a shared scrub cursor.
public struct SeriesChart: View {
    private let primary: [ChartPoint]
    private let secondary: [ChartPoint]
    private let color: Color
    private let secondaryColor: Color
    private let domain: ClosedRange<Date>
    private let ceiling: Double
    private let showsAxes: Bool
    private let yLabel: (Double) -> String
    private let scrub: ScrubState?

    /// - Parameters:
    ///   - yMax: Fixed ceiling (1 for percentages); nil rounds the data maximum up to a readable tick.
    ///   - showsAxes: Time labels along the bottom and value ticks on the trailing edge.
    public init(
        primary: [ChartPoint],
        secondary: [ChartPoint] = [],
        color: Color,
        secondaryColor: Color? = nil,
        domain: ClosedRange<Date>,
        yMax: Double? = nil,
        showsAxes: Bool = false,
        yLabel: @escaping (Double) -> String = { Format.percent($0, digits: 0) },
        scrub: ScrubState? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.color = color
        self.secondaryColor = secondaryColor ?? color
        self.domain = domain
        let dataMax = max(SeriesMath.peak(primary) ?? 0, SeriesMath.peak(secondary) ?? 0)
        ceiling = yMax ?? SeriesMath.niceCeiling(dataMax * 1.1)
        self.showsAxes = showsAxes
        self.yLabel = yLabel
        self.scrub = scrub
    }

    public var body: some View {
        Chart {
            ForEach(primary, id: \.date) { point in
                AreaMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Series", "primary"))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.26), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Series", "primary"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(secondary, id: \.date) { point in
                LineMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Series", "secondary"))
                    .foregroundStyle(secondaryColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [3, 3]))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...ceiling)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                // Short windows need seconds, or every tick reads the same minute; greedy drops ticks that would collide.
                AxisValueLabel(
                    format: domain.upperBound.timeIntervalSince(domain.lowerBound) <= 180
                        ? .dateTime.hour().minute().second()
                        : .dateTime.hour().minute(),
                    collisionResolution: .greedy
                )
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(yLabel(number)).monospacedDigit() }
                }
            }
        }
        .chartXAxis(showsAxes ? .visible : .hidden)
        .chartYAxis(showsAxes ? .visible : .hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            if let scrub { ScrubOverlay(proxy: proxy, scrub: scrub, domain: domain) }
        }
    }
}

private struct ScrubOverlay: View {
    let proxy: ChartProxy
    let scrub: ScrubState
    let domain: ClosedRange<Date>

    var body: some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            let x = min(max(location.x - plot.minX, 0), plot.width)
                            scrub.date = proxy.value(atX: x, as: Date.self).map { min(max($0, domain.lowerBound), domain.upperBound) }
                        case .ended:
                            scrub.date = nil
                        }
                    }
                if let date = scrub.date, let x = proxy.position(forX: date) {
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: 1, height: plot.height)
                        .offset(x: plot.minX + x - 0.5, y: plot.minY)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
