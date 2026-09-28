import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Markers: the selected marker in detail at the top, every marker as a card below.
struct MarkersScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let detailAnchor = "marker-detail"
    private static let endAnchor = "markers-end"

    var body: some View {
        let moments = monitor.moments
        let selected = moments.first { $0.id == appModel.selectedMarkerID } ?? moments.first
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.gap) {
                    PageHeader("Markers", subtitle: "Points in time you flagged, with the 2 minutes before and 30 seconds after.") {
                        if !moments.isEmpty {
                            AddMarkerButton()
                        }
                    }
                    .id(Self.detailAnchor)

                    if let pending = monitor.pendingMomentDate {
                        PendingMarkerBanner(date: pending)
                    }

                    if let selected {
                        MarkerDetail(moment: selected)
                            .id(selected.id)

                        SectionCard("All Markers", subtitle: "Up to 100 are kept; the oldest go first.") {
                            Text(moments.count == 1 ? "1 marker" : "\(moments.count) markers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } content: {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                                ForEach(moments) { moment in
                                    MarkerCard(moment: moment, isSelected: moment.id == selected.id) {
                                        appModel.selectedMarkerID = moment.id
                                        if reduceMotion {
                                            proxy.scrollTo(Self.detailAnchor, anchor: .top)
                                        } else {
                                            withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(Self.detailAnchor, anchor: .top) }
                                        }
                                    }
                                }
                            }
                        }
                    } else if monitor.pendingMomentDate == nil {
                        EmptyStateView(
                            "No Markers Yet",
                            symbol: "flag",
                            message: "When something feels slow, choose Add Marker (⇧⌘S). CareMyMac keeps the 2 minutes before and 30 seconds after, along with the busiest apps."
                        ) {
                            Button("Add Marker") { monitor.saveMoment() }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .card()
                    }

                    PageFooter(note: "Markers keep 1-second samples around each flagged point.")
                        .id(Self.endAnchor)
                }
                .padding(Metrics.pagePadding)
            }
            #if DEBUG
            .onAppear {
                if UserDefaults.standard.bool(forKey: "CareMyMacSnapshotScrollToEnd") { proxy.scrollTo(Self.endAnchor, anchor: .bottom) }
            }
            #endif
        }
        .pageBackground()
    }
}

private struct AddMarkerButton: View {
    @Environment(LiveMonitor.self) private var monitor

    var body: some View {
        Button("Add Marker", systemImage: "flag") { monitor.saveMoment() }
            .disabled(monitor.pendingMomentDate != nil)
    }
}

/// Shown for the 30 seconds after adding a marker while its tail is captured.
private struct PendingMarkerBanner: View {
    let date: Date

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Adding marker… capturing the next 30 seconds").fontWeight(.medium)
                Text("Marked at \(date.formatted(date: .omitted, time: .standard)). Keep doing what you were doing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            TimelineView(.periodic(from: date, by: 1)) { context in
                let left = max(0, Int((date.addingTimeInterval(30).timeIntervalSince(context.date)).rounded(.up)))
                Text("\(left) s left")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

/// Compact summary card in the markers grid; selecting it shows the marker above.
private struct MarkerCard: View {
    let moment: SavedMoment
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let points = moment.cpuSeries.chartPoints
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(moment.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    Spacer(minLength: 8)
                    Text(moment.date, format: .dateTime.hour().minute())
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(moment.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .help(moment.displayTitle)

                SeriesChart(primary: points, color: Resource.cpu.color, domain: moment.window, yMax: 1)
                    .frame(height: 36)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                HStack(spacing: 12) {
                    Label(Format.percent(moment.snapshot.cpu.total, digits: 0), systemImage: Resource.cpu.symbol)
                    Label(Format.memory(moment.snapshot.memory.used), systemImage: Resource.memory.symbol)
                    if let app = moment.topApps.first {
                        Text(app.name).lineLimit(1).help(app.name)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .labelStyle(CompactLabelStyle())
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered && !isSelected ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear), in: shape)
            .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.clear), in: shape)
            .overlay(shape.strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator), lineWidth: isSelected ? 1 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(moment.displayTitle), \(moment.date.formatted(date: .abbreviated, time: .shortened))")
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Shared helpers

extension SavedMoment {
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Marker" : trimmed
    }

    /// The captured span: 2 minutes before the save to 30 seconds after, widened to the data when it runs longer.
    var window: ClosedRange<Date> {
        let lower = min(cpuSeries.first?.date ?? date, date.addingTimeInterval(-120))
        let upper = max(cpuSeries.last?.date ?? date, date.addingTimeInterval(30))
        return lower...upper
    }
}

extension Array where Element == SeriesPoint {
    /// Points for `SeriesChart`, thinned to at most 720 so long captures stay cheap to draw.
    var chartPoints: [ChartPoint] {
        let limit = 720
        let stride = Swift.max(1, (count + limit - 1) / limit)
        var result: [ChartPoint] = []
        result.reserveCapacity(count / stride + 1)
        for index in Swift.stride(from: 0, to: count, by: stride) {
            result.append(ChartPoint(date: self[index].date, value: self[index].value))
        }
        return result
    }
}
