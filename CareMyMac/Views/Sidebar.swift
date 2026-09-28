import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Sources, Mail style: Overview and the app lists first, then pages about the Mac, what CareMyMac watches for you, and upkeep. Settings is pinned below the list.
struct Sidebar: View {
    @Environment(AppModel.self) private var appModel
    @Environment(LiveMonitor.self) private var monitor

    var body: some View {
        @Bindable var appModel = appModel
        List(selection: $appModel.screen) {
            Section {
                row(.overview)
                ForEach(Screen.lists) { row($0) }
            }
            Section("Mac") {
                ForEach(Screen.mac) { row($0) }
            }
            Section("Watch") {
                ForEach(Screen.watch) { row($0) }
            }
            Section("Care") {
                ForEach(Screen.care) { row($0) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .help("CareMyMac settings (⌘,)")
        }
    }

    private func row(_ screen: Screen) -> some View {
        Label(screen.title, systemImage: screen.symbol(for: monitor.machine))
            .badge(badge(for: screen))
            .tag(screen)
    }

    private func badge(for screen: Screen) -> Int {
        switch screen {
        case .alerts: monitor.unreadAlertCount
        case .apps: monitor.apps.lazy.filter { AppFilter.applications.includes($0) && AppFilter.isBusy($0) }.count
        default: 0
        }
    }
}
