import CareMyMacKit
import CareMyMacUI

/// Plain-language status under page titles and in the menu bar extra.
@MainActor
enum MacStatus {
    static func sentence(for monitor: LiveMonitor) -> String {
        guard let s = monitor.snapshot else { return "Taking a first look…" }
        if monitor.isPaused { return "Monitoring is paused." }
        if s.memory.pressure == .critical { return "Memory is running out." }
        if s.cpu.total > 0.75 { return "Your Mac is working hard." }
        if s.memory.pressure == .warning { return "Memory is getting tight." }
        if let app = monitor.apps.first, app.cpu > 0.8 { return "\(app.name) is keeping your Mac busy." }
        return "Your Mac is taking it easy."
    }
}
