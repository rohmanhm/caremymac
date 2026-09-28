import AppKit
import CareMyMacUI
import SwiftUI

/// Switches the monitor between its visible and hidden refresh intervals.
///
/// The app counts as visible while the main window or the open menu bar panel is on screen and not fully covered.
/// The status item itself and the Settings window don't show live data, so they don't count.
@MainActor
final class WindowVisibility {
    /// Windows registered by `countsAsVisibleWindow()`.
    static let liveWindows = NSHashTable<NSWindow>.weakObjects()

    private let monitor: LiveMonitor
    private var observers: [NSObjectProtocol] = []

    init(monitor: LiveMonitor) {
        self.monitor = monitor
    }

    func start() {
        let center = NotificationCenter.default
        let windowEvents: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        let appEvents: [Notification.Name] = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        for name in windowEvents + appEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                let closingID = closing.map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.update(excluding: closingID) }
            })
        }
    }

    private func update(excluding closing: ObjectIdentifier?) {
        let visible = !NSApp.isHidden && NSApp.windows.contains { window in
            ObjectIdentifier(window) != closing && Self.showsLiveData(window) && Self.isOnScreen(window)
        }
        if monitor.isAppVisible != visible { monitor.isAppVisible = visible }
    }

    private static func isOnScreen(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// The main window, or the menu bar panel. Status item buttons live in `NSStatusBarWindow` and never count.
    private static func showsLiveData(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.contains(WindowID.main) == true || liveWindows.contains(window)
    }
}

extension View {
    /// Counts the hosting window as showing live data, e.g. the menu bar panel.
    func countsAsVisibleWindow() -> some View {
        background(LiveWindowMarker().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct LiveWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ nsView: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowVisibility.liveWindows.add(window) }
        }
    }
}
