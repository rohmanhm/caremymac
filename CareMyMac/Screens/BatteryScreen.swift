import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Internal battery charge and condition, plus connected accessory batteries.
struct BatteryScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @AppStorage("liveRange") private var range: LiveRange = .fiveMinutes
    @State private var scrub = ScrubState()

    var body: some View {
        let battery = monitor.snapshot?.battery
        let domain = monitor.domain(range)
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("Battery", subtitle: "Power source, charging, and battery condition.") {
                    ThermalBadge()
                }

                if let battery {
                    ResourceChartCard(
                        title: "Charge",
                        subtitle: battery.state.label,
                        resource: .battery,
                        primary: ChartSeries(label: "Charge", points: monitor.series.battery.points(since: domain.lowerBound)),
                        yMax: 1,
                        format: { Format.percent($0, digits: 0) },
                        scrub: scrub,
                        domain: domain
                    )

                    HStack(alignment: .top, spacing: Metrics.gap) {
                        StatTile("Charge", value: Format.percent(battery.level, digits: 0), detail: battery.state.label)
                        StatTile("Power source", value: battery.isPluggedIn ? "Power adapter" : "Battery")
                        StatTile("Time remaining", value: timeRemaining(battery),
                                 detail: battery.state == .charging ? "Until full" : battery.isPluggedIn ? nil : "Until empty")
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    ConditionCard(battery: battery)
                } else {
                    EmptyStateView(
                        "No internal battery",
                        symbol: "powerplug",
                        message: "This Mac runs on wall power. Charge and condition appear here on Macs with a built-in battery."
                    )
                    .card()
                }

                if battery != nil || !monitor.accessoryBatteries.isEmpty {
                    AccessoriesCard(accessories: monitor.accessoryBatteries)
                }

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
    }

    private func timeRemaining(_ battery: BatteryStats) -> String {
        if let time = battery.timeRemaining, time > 0 { return Format.duration(time) }
        switch battery.state {
        case .charged: return "Full"
        case .notCharging: return "Not charging"
        case .charging, .discharging: return "Calculating…"
        }
    }
}

private struct ConditionCard: View {
    let battery: BatteryStats

    var body: some View {
        SectionCard("Condition", subtitle: battery.condition.map { "macOS reports: \($0)" }) {
            let rows = self.rows
            let half = (rows.count + 1) / 2
            HStack(alignment: .top, spacing: 32) {
                KeyValueGrid(rows: Array(rows[..<half]))
                KeyValueGrid(rows: Array(rows[half...]))
            }
        }
    }

    private var rows: [(String, String)] {
        var power = Format.unavailable
        if let watts = battery.powerWatts {
            power = watts < 0 ? "Charging at \(Format.decimal(-watts, digits: 1)) W" : "\(Format.decimal(watts, digits: 1)) W"
        }
        let health = battery.health.map { "\(Format.percent($0, digits: 0)) max capacity" } ?? Format.unavailable
        return [
            ("State", battery.state.label),
            ("Health", health),
            ("Cycle count", battery.cycleCount.map { Format.integer($0) } ?? Format.unavailable),
            ("Design capacity", battery.designCapacity.map { "\(Format.integer($0)) mAh" } ?? Format.unavailable),
            ("Temperature", battery.temperatureCelsius.map { "\(Format.decimal($0, digits: 1)) °C" } ?? Format.unavailable),
            ("Battery power", power),
            ("Adapter", battery.adapterWatts.map { "\($0) W" } ?? (battery.isPluggedIn ? Format.unavailable : "Not connected")),
        ]
    }
}

private struct KeyValueGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AccessoriesCard: View {
    let accessories: [AccessoryBattery]

    var body: some View {
        SectionCard("Accessories", subtitle: "Bluetooth devices that report a battery level") {
            if accessories.isEmpty {
                Text("No accessories reporting a battery. Connected mice, keyboards, trackpads, and headphones show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 12) {
                    ForEach(accessories) { accessory in
                        HStack(spacing: 12) {
                            Text(accessory.name).lineLimit(1).help(accessory.name)
                                .frame(width: 200, alignment: .leading)
                            LevelBar(value: accessory.level, color: Resource.battery.color)
                                .accessibilityLabel("\(accessory.name) battery")
                            Text(Format.percent(accessory.level, digits: 0))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                            if accessory.isCharging == true {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(Resource.battery.color)
                                    .accessibilityLabel("Charging")
                            }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

/// Capsule capacity bar tinted with the resource color.
private struct LevelBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule().fill(color)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityValue(Format.percent(value, digits: 0))
    }
}
