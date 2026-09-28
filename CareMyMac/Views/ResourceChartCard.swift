import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// A named series drawn by `ResourceChartCard`.
struct ChartSeries {
    let label: String
    let points: [ChartPoint]
}

/// The big chart on every resource page: live readout on the left (scrubbable), chart with axes on the right.
struct ResourceChartCard: View {
    let title: String
    let subtitle: String
    let resource: Resource
    let primary: ChartSeries
    var secondary: ChartSeries?
    /// Fixed ceiling (1 for percentages); nil scales to the data.
    var yMax: Double?
    let format: (Double) -> String
    let scrub: ScrubState
    let domain: ClosedRange<Date>

    @AppStorage("liveRange") private var range: LiveRange = .fiveMinutes

    var body: some View {
        SectionCard(title, subtitle: subtitle) {
            RangePicker()
        } content: {
            HStack(alignment: .top, spacing: 24) {
                ChartReadout(primary: primary, secondary: secondary, format: format, scrub: scrub)
                    .frame(width: 168, alignment: .leading)
                SeriesChart(
                    primary: primary.points,
                    secondary: secondary?.points ?? [],
                    color: resource.color,
                    secondaryColor: resource.secondaryColor,
                    domain: domain,
                    yMax: yMax,
                    showsAxes: true,
                    yLabel: yMax == 1 ? { Format.percent($0, digits: 0) } : format,
                    scrub: scrub
                )
                .frame(height: 170)
                .accessibilityLabel("\(title) chart, \(range.longLabel.lowercased())")
            }
            HStack(spacing: 16) {
                LegendSwatch(primary.label, color: resource.color)
                if let secondary {
                    LegendSwatch(secondary.label, color: resource.secondaryColor, dashed: true)
                }
                Spacer()
                Text("\(range.longLabel) · hover for exact values")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Reads the scrub cursor, so hovering only re-renders these labels.
private struct ChartReadout: View {
    let primary: ChartSeries
    let secondary: ChartSeries?
    let format: (Double) -> String
    let scrub: ScrubState

    var body: some View {
        let date = scrub.date
        let now = date.map { SeriesMath.value(in: primary.points, at: $0) } ?? primary.points.last?.value
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(date.map { $0.formatted(date: .omitted, time: .standard) } ?? "Now")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(now.map(format) ?? Format.unavailable)
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let secondary {
                    let value = date.map { SeriesMath.value(in: secondary.points, at: $0) } ?? secondary.points.last?.value
                    Text("\(secondary.label) \(value.map(format) ?? Format.unavailable)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Average").foregroundStyle(.secondary)
                    Text(SeriesMath.average(primary.points).map(format) ?? Format.unavailable).gridColumnAlignment(.trailing)
                }
                GridRow {
                    Text("Peak").foregroundStyle(.secondary)
                    Text(SeriesMath.peak(primary.points).map(format) ?? Format.unavailable)
                }
            }
            .font(.callout)
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
