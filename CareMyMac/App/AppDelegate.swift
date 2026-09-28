import AppKit
import CareMyMacKit
import CareMyMacUI
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Declared before `monitor`: stored properties initialize in order, and opening the store creates it.
    let onboarding = Onboarding(storeExists: FileManager.default.fileExists(atPath: AppDelegate.storeURL.path(percentEncoded: false)))
    let monitor = LiveMonitor(engine: MonitorEngine(storeURL: AppDelegate.storeURL))
    let appModel = AppModel()
    let notifier = AlertNotifier()
    let loginItem = LoginItem()
    let menuBar = MenuBarVisibility()
    let updater = Updater()
    private lazy var visibility = WindowVisibility(monitor: monitor)
    /// SwiftUI's window opener, captured by the first scene view that appears. AppKit callbacks have no environment.
    var openWindow: OpenWindowAction?
    var openSettings: OpenSettingsAction?

    /// Debug builds accept `-CareMyMacStore <path>` so test runs never touch real history.
    static var storeURL: URL {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "CareMyMacStore") {
            return URL(fileURLWithPath: path)
        }
        #endif
        return HistoryStore.defaultURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsKey.registerDefaults()
        MonitorPreferences.apply(to: monitor)
        UNUserNotificationCenter.current().delegate = self
        monitor.onNewAlerts = { [notifier] events in notifier.post(events) }
        monitor.start()
        updater.start()
        visibility.start()
        #if DEBUG
        DebugSnapshot.runIfRequested(monitor: monitor, appModel: appModel)
        DebugExtras.runIfRequested(delegate: self)
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let keepsRunningInMenuBar = UserDefaults.standard.object(forKey: SettingsKey.menuBarEnabled) as? Bool ?? true
        return !keepsRunningInMenuBar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return false
    }

    /// Brings the main window forward, recreating it if it was closed.
    func showMainWindow(screen: Screen? = nil) {
        if let screen { appModel.screen = screen }
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(WindowID.main) == true }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: WindowID.main)
        }
        NSApp.activate()
    }

    /// Help ▸ Welcome to CareMyMac: the first-run sheet again, over the main window.
    func showWelcome() {
        showMainWindow()
        onboarding.isPresented = true
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { showMainWindow(screen: .alerts) }
    }
}

extension View {
    /// Hands SwiftUI's `openWindow` and `openSettings` to the app delegate so AppKit callbacks (Dock, notifications) can reopen the main window.
    func capturesOpenWindow(for delegate: AppDelegate) -> some View {
        modifier(OpenWindowCapture(delegate: delegate))
    }
}

private struct OpenWindowCapture: ViewModifier {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.openWindow = openWindow
            delegate.openSettings = openSettings
        }
    }
}
