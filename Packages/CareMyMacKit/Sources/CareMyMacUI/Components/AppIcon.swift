import AppKit
import CareMyMacKit
import SwiftUI

/// Finder icon for an app bundle or executable path; generic app icon when unknown.
public struct AppIcon: View {
    private let path: String?
    private let size: CGFloat

    public init(path: String?, size: CGFloat = 20) {
        self.path = path
        self.size = size
    }

    public init(app: AppActivity, size: CGFloat = 20) {
        self.init(path: app.bundlePath, size: size)
    }

    public var body: some View {
        Image(nsImage: IconCache.shared.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var icons: [String: NSImage] = [:]
    private lazy var generic = NSWorkspace.shared.icon(for: .application)

    func icon(for path: String?) -> NSImage {
        guard let path, !path.isEmpty else { return generic }
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}
