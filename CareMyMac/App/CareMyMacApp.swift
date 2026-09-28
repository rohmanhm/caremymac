import CareMyMacKit
import CareMyMacUI
import SwiftUI

@main
struct CareMyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("CareMyMac", id: WindowID.main) {
            RootView()
                .environment(delegate.monitor)
                .environment(delegate.appModel)
                .capturesOpenWindow(for: delegate)
        }
        .defaultSize(width: 1280, height: 880)
        .windowToolbarStyle(.unified)
        .commands { CareMyMacCommands(monitor: delegate.monitor, appModel: delegate.appModel) }

        Settings {
            SettingsView()
                .environment(delegate.monitor)
                .environment(delegate.appModel)
                .environment(delegate.notifier)
                .environment(delegate.loginItem)
                .capturesOpenWindow(for: delegate)
        }
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: Bindable(delegate.menuBar).isInserted) {
            MenuBarContent()
                .countsAsVisibleWindow()
                .environment(delegate.monitor)
                .environment(delegate.appModel)
        } label: {
            MenuBarLabel()
                .environment(delegate.monitor)
                .capturesOpenWindow(for: delegate)
        }
        .menuBarExtraStyle(.window)
    }
}

enum WindowID {
    static let main = "main"
}
