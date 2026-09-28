import AppKit
import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Pause and Add Marker on every page. Sharing lives in the File menu.
struct MainToolbar: ToolbarContent {
    @Environment(LiveMonitor.self) private var monitor

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(monitor.isPaused ? "Resume" : "Pause", systemImage: monitor.isPaused ? "play.fill" : "pause.fill") {
                monitor.togglePause()
            }
            .help(monitor.isPaused ? "Resume monitoring" : "Pause monitoring")

            Button("Add Marker", systemImage: monitor.pendingMomentDate == nil ? "flag" : "flag.fill") {
                monitor.saveMoment()
            }
            .help(monitor.pendingMomentDate == nil ? "Mark this point in time, with the 2 minutes before it" : "Adding marker: recording the next 30 seconds")
            .disabled(monitor.pendingMomentDate != nil || monitor.snapshot == nil)
        }
    }
}

/// Menu commands mirror the toolbar so everything has a keyboard path.
struct CareMyMacCommands: Commands {
    let monitor: LiveMonitor
    let appModel: AppModel
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        CommandGroup(after: .saveItem) {
            Divider()
            // The summary is built on click, so the menu never re-renders with live data.
            Button("Share Summary…") { ShareSummary.share(for: monitor) }
            Button("Copy Summary") { ShareSummary.copy(for: monitor) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandMenu("Monitor") {
            Button(monitor.isPaused ? "Resume Monitoring" : "Pause Monitoring") { monitor.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Add Marker") { monitor.saveMoment() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(monitor.pendingMomentDate != nil)
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(Screen.allCases.enumerated()), id: \.element) { index, screen in
                if index < 9 {
                    Button(screen.title) { appModel.screen = screen }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }
}

@MainActor
enum ShareSummary {
    /// macOS share sheet for the summary, anchored to the top of the key window.
    static func share(for monitor: LiveMonitor) {
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [text(for: monitor)])
        picker.show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    static func copy(for monitor: LiveMonitor) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: monitor), forType: .string)
    }

    static func text(for monitor: LiveMonitor) -> String {
        guard let s = monitor.snapshot else { return "CareMyMac hasn't taken a measurement yet." }
        var lines = [
            "CareMyMac snapshot · \(s.date.formatted(date: .abbreviated, time: .standard))",
            "\(monitor.machine.modelName) · \(monitor.machine.chipName)",
            "CPU \(Format.percent(s.cpu.total)) (user \(Format.percent(s.cpu.user)), system \(Format.percent(s.cpu.system)))",
            "Memory \(Format.memory(s.memory.used)) of \(Format.memory(s.memory.physical)) · \(s.memory.pressure.label) pressure",
            "Disk read \(Format.rate(s.disk.readBytesPerSecond)) · write \(Format.rate(s.disk.writeBytesPerSecond))",
            "Network down \(Format.rate(s.network.receivedBytesPerSecond)) · up \(Format.rate(s.network.sentBytesPerSecond))",
        ]
        if let gpu = s.gpu { lines.append("GPU \(Format.percent(gpu.utilization)) · \(gpu.name)") }
        if let battery = s.battery { lines.append("Battery \(Format.percent(battery.level, digits: 0)) · \(battery.state.label)") }
        lines.append("")
        lines.append("Busiest apps:")
        for app in monitor.apps.prefix(5) {
            lines.append("• \(app.name): \(Format.percent(app.cpu)) CPU, \(Format.memory(app.memory))")
        }
        return lines.joined(separator: "\n")
    }
}
