import CoreServices
import Foundation

/// An app bundle the user installed, as listed on the Uninstaller page.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    /// Display name, then bundle name, then the file name without “.app”.
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    /// Installed from the Mac App Store (`Contents/_MASReceipt` exists).
    public let isAppStore: Bool
    /// Bundle identifiers of login items, extensions and privileged helpers shipped inside the bundle.
    public internal(set) var helperBundleIdentifiers: [String]
    /// Names the app’s folders may use: the display name, bundle name and file name, without duplicates.
    public let names: [String]

    public init(url: URL, name: String, bundleIdentifier: String?, version: String?, isAppStore: Bool, helperBundleIdentifiers: [String], names: [String]) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.isAppStore = isAppStore
        self.helperBundleIdentifiers = helperBundleIdentifiers
        self.names = names
    }

    /// The app’s own identifier followed by its helpers’, for leftover matching.
    public var allBundleIdentifiers: [String] {
        (bundleIdentifier.map { [$0] } ?? []) + helperBundleIdentifiers
    }
}

/// Finds removable apps in the Applications folders.
public enum UninstallAppFinder {
    /// `/Applications` and `~/Applications`.
    public static func standardRoots(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    /// Apps directly in each root or one folder below it (e.g. `/Applications/Microsoft Office/Word.app`), sorted by name.
    /// Never looks inside bundles and never follows symlinks. Skips Apple apps, anything under `/System`, and `excluding` bundle IDs.
    /// Helper identifiers shipped by more than one app (a shared updater, say) are dropped, so no app claims another’s files.
    public static func apps(in roots: [URL], excluding excluded: Set<String> = []) throws -> [InstalledApp] {
        var seen = Set<String>()
        var found: [InstalledApp] = []
        for root in roots {
            for entry in entries(of: root) {
                try Task.checkCancellation()
                let candidates = isApp(entry) ? [entry] : (isPlainFolder(entry) ? entries(of: entry).filter(isApp) : [])
                for url in candidates {
                    let path = url.standardizedFileURL.path
                    guard !isSystemPath(path), seen.insert(path).inserted, let app = app(at: url) else { continue }
                    if let id = app.bundleIdentifier, isAppleIdentifier(id) || excluded.contains(id) { continue }
                    found.append(app)
                }
            }
        }
        var owners: [String: Set<String>] = [:]
        for app in found {
            for helper in app.helperBundleIdentifiers { owners[helper.lowercased(), default: []].insert(app.bundleIdentifier?.lowercased() ?? app.id) }
        }
        for index in found.indices {
            found[index].helperBundleIdentifiers.removeAll { owners[$0.lowercased(), default: []].count > 1 }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads one bundle’s Info.plist. Nil when it has none.
    public static func app(at url: URL) -> InstalledApp? {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        guard let info = infoPlist(in: url) else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        let displayName = nonEmpty(info["CFBundleDisplayName"])
        let bundleName = nonEmpty(info["CFBundleName"])
        var names: [String] = []
        for candidate in [displayName, bundleName, fileName].compactMap(\.self)
        where !names.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            names.append(candidate)
        }
        let id = nonEmpty(info["CFBundleIdentifier"])
        let version = nonEmpty(info["CFBundleShortVersionString"]) ?? nonEmpty(info["CFBundleVersion"])
        return InstalledApp(
            url: url,
            name: displayName ?? bundleName ?? fileName,
            bundleIdentifier: id,
            version: version,
            isAppStore: FileManager.default.fileExists(atPath: contents.appending(path: "_MASReceipt").path),
            helperBundleIdentifiers: helperIdentifiers(in: contents, excluding: id),
            names: names
        )
    }

    /// When the app was last opened, from Spotlight. Nil when Spotlight never recorded it.
    public static func lastUsedDate(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func isAppleIdentifier(_ id: String) -> Bool {
        id.lowercased().hasPrefix("com.apple.")
    }

    // MARK: Private

    /// Identifiers of login items, app extensions and privileged helpers. Helpers in `LaunchServices` are bare
    /// executables named after their launchd label, so the file name is the identifier. Only helpers from the app’s
    /// own vendor domain count (`com.vendor.*` for `com.vendor.app`); bundled third-party helpers belong to someone else.
    private static func helperIdentifiers(in contents: URL, excluding own: String?) -> [String] {
        guard let own, let vendor = vendorDomain(own) else { return [] }
        var ids: [String] = []
        let bundles = entries(of: contents.appending(path: "Library/LoginItems", directoryHint: .isDirectory)).filter { $0.pathExtension == "app" }
            + entries(of: contents.appending(path: "PlugIns", directoryHint: .isDirectory)).filter { $0.pathExtension == "appex" }
        for bundle in bundles {
            if let id = nonEmpty(infoPlist(in: bundle)?["CFBundleIdentifier"]) { ids.append(id) }
        }
        for tool in entries(of: contents.appending(path: "Library/LaunchServices", directoryHint: .isDirectory)) where tool.lastPathComponent.contains(".") {
            ids.append(tool.lastPathComponent)
        }
        var unique: [String] = []
        for id in ids where !isAppleIdentifier(id) && id.caseInsensitiveCompare(own) != .orderedSame && vendorDomain(id) == vendor
            && !unique.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) {
            unique.append(id)
        }
        return unique
    }

    /// The first two components of a reverse-DNS identifier, lowercased: “com.vendor”.
    private static func vendorDomain(_ id: String) -> String? {
        let parts = id.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0]).\(parts[1])"
    }

    private static func infoPlist(in bundle: URL) -> [String: Any]? {
        let url = bundle.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Visible entries of a folder, without resolving symlinks. Empty when the folder can’t be read.
    private static func entries(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
    }

    private static func isApp(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app" && isRealDirectory(url)
    }

    /// A folder that isn’t itself a bundle or package, so it may group apps.
    private static func isPlainFolder(_ url: URL) -> Bool {
        guard isRealDirectory(url) else { return false }
        return (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isSystemPath(_ path: String) -> Bool {
        path == "/System" || path.hasPrefix("/System/")
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !string.isEmpty else { return nil }
        return string
    }
}
