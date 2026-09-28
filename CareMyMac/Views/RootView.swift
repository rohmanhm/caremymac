import CareMyMacKit
import CareMyMacUI
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            ScreenView(screen: appModel.screen)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(appModel.screen.title)
                .toolbar { MainToolbar() }
        }
        .frame(minWidth: 1100, minHeight: 640)
    }
}

/// Maps a sidebar source to its content. Pages are rebuilt on switch, so each starts at the top.
struct ScreenView: View {
    let screen: Screen

    var body: some View {
        if let filter = screen.appFilter {
            AppBrowser(screen: screen, filter: filter)
        } else {
            switch screen {
            case .developer: DeveloperScreen()
            case .thisMac: ThisMacScreen()
            case .storage: StorageScreen()
            case .timeline: TimelineScreen()
            case .alerts: AlertsScreen()
            case .markers: MarkersScreen()
            case .cleanup: CleanupScreen()
            case .uninstaller: UninstallerScreen()
            case .optimize: OptimizeScreen()
            case .busy, .allApps, .background: EmptyView()
            }
        }
    }
}
