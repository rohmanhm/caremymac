import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// One resource's live reading, shared by all three variants so only the presentation differs.
struct Reading {
    let resource: Resource
    let value: String
    let detail: String
    let primary: [ChartPoint]
    var secondary: [ChartPoint] = []
    var yMax: Double?
    let format: (Double) -> String
}

extension LiveMonitor {
    func readings(since: Date) -> [Reading] {
        let s = snapshot
        var result = [
            Reading(resource: .cpu, value: Format.percent(s?.cpu.total), detail: "user \(Format.percent(s?.cpu.user)) · system \(Format.percent(s?.cpu.system))",
                    primary: series.cpu.points(since: since), yMax: 1, format: { Format.percent($0) }),
            Reading(resource: .memory, value: s.map { Format.memory($0.memory.used) } ?? Format.unavailable,
                    detail: s.map { "of \(Format.memory($0.memory.physical)) · \($0.memory.pressure.label.lowercased()) pressure" } ?? "",
                    primary: series.memoryBytes.points(since: since), yMax: Double(max(machine.physicalMemory, 1)), format: { Format.memory($0) }),
            Reading(resource: .disk, value: Format.rate((s?.disk.readBytesPerSecond ?? 0) + (s?.disk.writeBytesPerSecond ?? 0)),
                    detail: "read \(Format.rate(s?.disk.readBytesPerSecond ?? 0)) · write \(Format.rate(s?.disk.writeBytesPerSecond ?? 0))",
                    primary: series.diskRead.points(since: since), secondary: series.diskWrite.points(since: since), format: Format.rate),
            Reading(resource: .network, value: Format.rate(s?.network.receivedBytesPerSecond ?? 0),
                    detail: "down · up \(Format.rate(s?.network.sentBytesPerSecond ?? 0))",
                    primary: series.networkIn.points(since: since), secondary: series.networkOut.points(since: since), format: Format.rate),
        ]
        if let gpu = s?.gpu, gpu.utilization != nil {
            result.append(Reading(resource: .graphics, value: Format.percent(gpu.utilization), detail: gpu.name,
                                  primary: series.gpu.points(since: since), yMax: 1, format: { Format.percent($0) }))
        }
        if let battery = s?.battery {
            result.append(Reading(resource: .battery, value: Format.percent(battery.level, digits: 0),
                                  detail: battery.state == .discharging ? "\(Format.duration(battery.timeRemaining)) left" : battery.state.label.lowercased(),
                                  primary: series.battery.points(since: since), yMax: 1, format: { Format.percent($0, digits: 0) }))
        }
        return result
    }

    var statusSentence: String {
        guard let s = snapshot else { return "Taking a first look…" }
        if isPaused { return "Monitoring is paused." }
        if s.memory.pressure == .critical { return "Memory is running out." }
        if s.cpu.total > 0.75 { return "Your Mac is working hard." }
        if s.memory.pressure == .warning { return "Memory is getting tight." }
        if let app = apps.first, app.cpu > 0.8 { return "\(app.name) is keeping your Mac busy." }
        return "Your Mac is taking it easy."
    }
}

extension AppActivity {
    func value(for resource: Resource) -> Double {
        switch resource {
        case .memory: Double(memory)
        case .disk: diskReadBytesPerSecond + diskWriteBytesPerSecond
        default: cpu
        }
    }

    func formatted(for resource: Resource) -> String {
        switch resource {
        case .memory: Format.memory(memory)
        case .disk: Format.rate(diskReadBytesPerSecond + diskWriteBytesPerSecond)
        default: Format.percent(cpu)
        }
    }
}
