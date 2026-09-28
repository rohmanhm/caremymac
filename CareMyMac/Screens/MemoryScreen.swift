import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Physical memory: usage over time, pressure, composition, and the apps holding it.
struct MemoryScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @AppStorage("liveRange") private var range: LiveRange = .fiveMinutes
    @State private var scrub = ScrubState()

    var body: some View {
        let m = monitor.snapshot?.memory
        let domain = monitor.domain(range)
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("Memory", subtitle: "Physical memory, pressure, and the apps using it.") {
                    ThermalBadge()
                }

                ResourceChartCard(
                    title: "Memory used",
                    subtitle: "Share of \(Format.memory(monitor.machine.physicalMemory)) installed",
                    resource: .memory,
                    primary: ChartSeries(label: "Memory", points: monitor.series.memory.points(since: domain.lowerBound)),
                    yMax: 1,
                    format: { Format.percent($0) },
                    scrub: scrub,
                    domain: domain
                )

                HStack(alignment: .top, spacing: Metrics.gap) {
                    StatTile("Memory used", value: m.map { Format.memory($0.used) } ?? Format.unavailable,
                             detail: m.map { "of \(Format.memory($0.physical))" })
                    StatTile("Pressure", value: m?.pressure.label ?? Format.unavailable, valueColor: m.map { pressureColor($0.pressure) } ?? nil)
                    StatTile("Swap used", value: m.map { Format.memory($0.swapUsed) } ?? Format.unavailable,
                             detail: m.map { $0.swapTotal > 0 ? "of \(Format.memory($0.swapTotal))" : "No swap file" })
                    StatTile("Cached files", value: m.map { Format.memory($0.cachedFiles) } ?? Format.unavailable, detail: "Reclaimable")
                }
                .fixedSize(horizontal: false, vertical: true)

                if let m {
                    MemoryBreakdownCard(memory: m)
                }

                TopApps(sort: .memory)

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
    }
}

private func pressureColor(_ pressure: MemoryPressure) -> Color? {
    switch pressure {
    case .normal: nil
    case .warning: Palette.warningText
    case .critical: Palette.critical
    }
}

private struct MemorySegment: Identifiable {
    let label: String
    let bytes: UInt64
    let color: Color
    let detail: String
    var id: String { label }
}

/// One stacked bar of the whole of RAM, in tones of the memory hue, plus a legend with values.
private struct MemoryBreakdownCard: View {
    let memory: MemoryStats

    private static let hue = Resource.memory.hue
    private static func tone(_ light: Double, _ dark: Double) -> Color {
        Color(light: .tone(l: light, h: hue, fraction: 0.85), dark: .tone(l: dark, h: hue, fraction: 0.75))
    }
    private static let appColor = tone(0.45, 0.78)
    private static let wiredColor = tone(0.58, 0.66)
    private static let compressedColor = tone(0.70, 0.54)
    private static let cachedColor = tone(0.82, 0.42)
    private static let freeColor = Color.secondary.opacity(0.18)

    var body: some View {
        let segments = [
            MemorySegment(label: "App", bytes: memory.app, color: Self.appColor, detail: "Used by apps and their helpers"),
            MemorySegment(label: "Wired", bytes: memory.wired, color: Self.wiredColor, detail: "Kept in RAM by the system"),
            MemorySegment(label: "Compressed", bytes: memory.compressed, color: Self.compressedColor, detail: "Squeezed to make room"),
            MemorySegment(label: "Cached files", bytes: memory.cachedFiles, color: Self.cachedColor, detail: "Freed instantly when needed"),
            MemorySegment(label: "Free", bytes: memory.free, color: Self.freeColor, detail: "Not in use"),
        ]
        let total = max(Double(segments.reduce(0) { $0 + $1.bytes }), 1)
        SectionCard("Memory", subtitle: "\(Format.memory(memory.physical)) installed") {
            Text("Pressure: \(memory.pressure.label)")
                .font(.callout)
                .foregroundStyle(pressureColor(memory.pressure) ?? .secondary)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(segments) { segment in
                            Rectangle()
                                .fill(segment.color)
                                .frame(width: max(0, (geometry.size.width - 8) * Double(segment.bytes) / total))
                        }
                    }
                }
                .frame(height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Memory composition")
                .accessibilityValue(segments.map { "\($0.label) \(Format.memory($0.bytes))" }.joined(separator: ", "))

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(segments) { segment in
                        GridRow {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(segment.color)
                                .frame(width: 10, height: 10)
                            Text(segment.label)
                            Text(segment.detail).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Format.memory(segment.bytes)).monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text(Format.percent(Double(segment.bytes) / total, digits: 0))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                }

                Divider()
                HStack {
                    Text("Swap").font(.callout)
                    Spacer()
                    Text(memory.swapTotal > 0
                         ? "\(Format.memory(memory.swapUsed)) used of \(Format.memory(memory.swapTotal))"
                         : "No swap in use")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
