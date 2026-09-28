import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// "Local & private" and the refresh cadence, at the end of every page.
struct PageFooter: View {
    @Environment(LiveMonitor.self) private var monitor
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Label("Local & private", systemImage: "lock")
            if let note {
                Text(note).lineLimit(2)
            }
            Spacer(minLength: 12)
            Text(monitor.isPaused ? "Paused" : "Live · every \(Format.decimal(monitor.interval, digits: 0)) seconds")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
}

/// Thermal state badge for page headers.
struct ThermalBadge: View {
    @Environment(LiveMonitor.self) private var monitor

    var body: some View {
        let state = monitor.thermalState
        Label(state.label, systemImage: "thermometer.medium")
            .font(.callout)
            .foregroundStyle(state == .nominal ? AnyShapeStyle(.secondary) : AnyShapeStyle(state == .critical ? Palette.critical : Palette.warningText))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.fill.tertiary, in: Capsule())
            .help("Thermal state reported by macOS")
            .accessibilityLabel("Thermal state \(state.label)")
    }
}
