import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Sources, Mail style: app lists first, then pages about the Mac, what CareMyMac watches for you, and upkeep.
struct Sidebar: View {
    @Environment(AppModel.self) private var appModel
    @Environment(LiveMonitor.self) private var monitor

    var body: some View {
        @Bindable var appModel = appModel
        List(selection: $appModel.screen) {
            Section {
                ForEach(Screen.apps) { row($0) }
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
    }

    private func row(_ screen: Screen) -> some View {
        Label(screen.title, systemImage: screen.symbol)
            .badge(badge(for: screen))
            .tag(screen)
    }

    private func badge(for screen: Screen) -> Int {
        switch screen {
        case .alerts: monitor.unreadAlertCount
        case .busy: monitor.apps.lazy.filter(AppFilter.busy.includes).count
        default: 0
        }
    }
}
