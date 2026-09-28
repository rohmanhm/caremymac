import AppKit
import CareMyMacKit
import CareMyMacUI
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        switch ProcessInfo.processInfo.environment["PROTO_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        NSApp.activate()
        // Harness-only: PROTO_SNAPSHOT=<file.png> renders the window after PROTO_WAIT seconds, then exits.
        if let path = ProcessInfo.processInfo.environment["PROTO_SNAPSHOT"] {
            let wait = Double(ProcessInfo.processInfo.environment["PROTO_WAIT"] ?? "") ?? 20
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct IdentityProtoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Real store: the Journal reads today's real history. Recording a few minutes more is harmless.
    @State private var monitor = LiveMonitor()
    @State private var trails = AppTrails()

    var body: some Scene {
        WindowGroup("CareMyMac — identity prototype") {
            Harness()
                .environment(monitor)
                .environment(trails)
                .onAppear { monitor.start() }
                .onChange(of: monitor.snapshot?.date) { trails.record(monitor.apps, at: monitor.snapshot?.date ?? .now) }
        }
        .defaultSize(width: 1280, height: 860)
    }
}

/// Per-app CPU and memory trails (prototype-local; the real app doesn't keep these yet).
@MainActor
@Observable
final class AppTrails {
    private(set) var cpu: [String: TimeSeries<Double>] = [:]
    private(set) var memory: [String: TimeSeries<Double>] = [:]

    func record(_ apps: [AppActivity], at date: Date) {
        for app in apps.prefix(60) {
            cpu[app.id, default: TimeSeries(capacity: 300)].append(app.cpu, at: date)
            memory[app.id, default: TimeSeries(capacity: 300)].append(Double(app.memory), at: date)
        }
    }
}
