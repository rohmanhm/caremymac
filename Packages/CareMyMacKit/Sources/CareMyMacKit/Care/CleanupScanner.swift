import AppKit
import Foundation

/// Groups on the Cleanup page whose items move to the Trash. The Trash itself is handled by `CleanupTrash`.
public enum CleanupCategory: Int, CaseIterable, Sendable, Hashable, Identifiable, Comparable {
    case userCaches
    case logs
    case developer
    case installers

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .userCaches: "User Caches"
        case .logs: "Logs"
        case .developer: "Developer Junk"
        case .installers: "Old Installers"
        }
    }

    public static func < (lhs: CleanupCategory, rhs: CleanupCategory) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One folder or file the Cleanup page can move to the Trash.
public struct CleanupItem: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let category: CleanupCategory
    public let name: String
    public let url: URL
    public let isSelectedByDefault: Bool
    /// Why the item is (un)selected or what recreates it, e.g. "In use by Safari".
    public let note: String?
    /// Content modification date; set for old installers.
    public let modified: Date?

    public init(category: CleanupCategory, name: String, url: URL, isSelectedByDefault: Bool, note: String? = nil, modified: Date? = nil) {
        self.category = category
        self.name = name
        self.url = url
        self.isSelectedByDefault = isSelectedByDefault
        self.note = note
        self.modified = modified
    }
}

/// Everything discovery depends on, injected so tests can use a scratch home folder.
public struct CleanupEnvironment: Sendable {
    public var home: URL
    /// Running apps: lowercased bundle ID → display name.
    public var runningApps: [String: String]
    /// Display name of the installed app with this bundle ID, or nil.
    public var appName: @Sendable (_ bundleID: String) -> String?

    public init(home: URL, runningApps: [String: String] = [:], appName: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.home = home
        self.runningApps = Dictionary(runningApps.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.appName = appName
    }

    /// This Mac: the user's home folder, `NSWorkspace` running apps and Launch Services names.
    @MainActor
    public static func current() -> CleanupEnvironment {
        var running: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            running[bundleID.lowercased()] = app.localizedName ?? bundleID
        }
        return CleanupEnvironment(home: FileManager.default.homeDirectoryForCurrentUser, runningApps: running) { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
    }
}

/// Result of listing the Cleanup locations, before anything is measured.
public struct CleanupDiscovery: Sendable {
    /// Every item, each path at most once, in category order.
    public var items: [CleanupItem]
    /// Categories whose folder macOS wouldn't let CareMyMac list (Full Disk Access or Files & Folders).
    public var blocked: Set<CleanupCategory>

    public init(items: [CleanupItem], blocked: Set<CleanupCategory>) {
        self.items = items
        self.blocked = blocked
    }
}

public enum CleanupScanner {
    /// Download extensions treated as installers, lowercased.
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]

    /// Lists every category. Fast: nothing is measured. Symlinks and hidden entries are never listed.
    public static func discover(_ environment: CleanupEnvironment) -> CleanupDiscovery {
        let home = environment.home
        var claims = Claims()
        var items: [CleanupItem] = []
        var blocked: Set<CleanupCategory> = []

        // Developer paths claim their folders first, so Yarn, Homebrew and friends never show up as user caches.
        for item in developerItems(home: home) where claims.claim(item.url) {
            items.append(item)
        }

        switch listing(home.appending(path: "Library/Caches", directoryHint: .isDirectory)) {
        case .success(let children):
            for child in children {
                let name = child.lastPathComponent
                guard !name.lowercased().hasPrefix("com.apple."), claims.claim(child) else { continue }
                items.append(cacheItem(child, environment: environment))
            }
        case .failure(.blocked): blocked.insert(.userCaches)
        case .failure: break
        }

        switch listing(home.appending(path: "Library/Logs", directoryHint: .isDirectory)) {
        case .success(let children):
            for child in children where claims.claim(child) {
                items.append(CleanupItem(category: .logs, name: child.lastPathComponent, url: child, isSelectedByDefault: true))
            }
        case .failure(.blocked): blocked.insert(.logs)
        case .failure: break
        }

        switch listing(home.appending(path: "Downloads", directoryHint: .isDirectory)) {
        case .success(let children):
            for child in children where installerExtensions.contains(child.pathExtension.lowercased()) && claims.claim(child) {
                let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                items.append(CleanupItem(category: .installers, name: child.lastPathComponent, url: child, isSelectedByDefault: false, modified: modified))
            }
        case .failure(.blocked): blocked.insert(.installers)
        case .failure: break
        }

        items.sort { $0.category < $1.category }
        return CleanupDiscovery(items: items, blocked: blocked)
    }

    /// Measures each URL with `CareFiles.allocatedSize`, at most `concurrency` at a time, reporting sizes as they finish.
    /// Throws `CancellationError` when the calling task is cancelled.
    public static func measure(_ urls: [URL], concurrency: Int = 4, report: @Sendable (URL, Int64) async -> Void) async throws {
        try await withThrowingTaskGroup(of: (URL, Int64).self) { group in
            var pending = urls.makeIterator()
            for _ in 0..<max(concurrency, 1) {
                guard let url = pending.next() else { break }
                group.addTask { (url, try CareFiles.allocatedSize(of: url)) }
            }
            while let (url, size) = try await group.next() {
                await report(url, size)
                if let url = pending.next() {
                    group.addTask { (url, try CareFiles.allocatedSize(of: url)) }
                }
            }
        }
    }

    // MARK: - Developer junk

    private struct DeveloperPath {
        let relative: String
        let name: String
        let note: String
    }

    private static let developerPaths: [DeveloperPath] = [
        DeveloperPath(relative: "Library/Developer/Xcode/DerivedData", name: "Xcode Derived Data", note: "Xcode rebuilds it on the next build."),
        DeveloperPath(relative: "Library/Developer/CoreSimulator/Caches", name: "Simulator caches", note: "Simulator recreates them when a device boots."),
        DeveloperPath(relative: ".npm/_cacache", name: "npm cache", note: "npm downloads packages again on the next install."),
        DeveloperPath(relative: "Library/Caches/Yarn", name: "Yarn cache", note: "Yarn downloads packages again on the next install."),
        DeveloperPath(relative: "Library/pnpm/store", name: "pnpm store", note: "pnpm downloads packages again on the next install."),
        DeveloperPath(relative: ".bun/install/cache", name: "Bun cache", note: "Bun downloads packages again on the next install."),
        DeveloperPath(relative: ".gradle/caches", name: "Gradle caches", note: "Gradle downloads dependencies again on the next build."),
        DeveloperPath(relative: ".cargo/registry/cache", name: "Cargo registry cache", note: "Cargo downloads crates again on the next build."),
        DeveloperPath(relative: "Library/Caches/Homebrew", name: "Homebrew downloads", note: "Homebrew downloads bottles again when it installs or upgrades."),
        DeveloperPath(relative: "Library/Caches/pip", name: "pip cache", note: "pip downloads packages again on the next install."),
        DeveloperPath(relative: "Library/Caches/go-build", name: "Go build cache", note: "Go rebuilds it on the next build."),
        DeveloperPath(relative: "Library/Caches/CocoaPods", name: "CocoaPods cache", note: "CocoaPods downloads pods again on the next install."),
    ]

    /// Developer caches that exist as real folders (not symlinks). Device support folders stay unselected.
    static func developerItems(home: URL) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let derivedData = developerPaths[0]
        let derivedURL = home.appending(path: derivedData.relative, directoryHint: .isDirectory)
        if kind(of: derivedURL) == .directory {
            items.append(CleanupItem(category: .developer, name: derivedData.name, url: derivedURL, isSelectedByDefault: true, note: derivedData.note))
        }

        if case .success(let children) = listing(home.appending(path: "Library/Developer/Xcode", directoryHint: .isDirectory)) {
            for child in children where child.lastPathComponent.hasSuffix("DeviceSupport") && kind(of: child) == .directory {
                let platform = child.lastPathComponent.dropLast("DeviceSupport".count).trimmingCharacters(in: .whitespaces)
                items.append(CleanupItem(
                    category: .developer,
                    name: platform.isEmpty ? "Device Support" : "\(platform) Device Support",
                    url: child,
                    isSelectedByDefault: false,
                    note: "Xcode copies it again from the device the next time it connects."
                ))
            }
        }

        for path in developerPaths.dropFirst() {
            let url = home.appending(path: path.relative, directoryHint: .isDirectory)
            guard kind(of: url) == .directory else { continue }
            items.append(CleanupItem(category: .developer, name: path.name, url: url, isSelectedByDefault: true, note: path.note))
        }
        return items
    }

    // MARK: - User caches

    private static func cacheItem(_ url: URL, environment: CleanupEnvironment) -> CleanupItem {
        let folder = url.lastPathComponent
        let name = (folder.contains(".") ? environment.appName(folder) : nil)
            ?? environment.runningApps[folder.lowercased()]
            ?? folder
        if let app = runningApp(owning: folder, in: environment.runningApps) {
            return CleanupItem(category: .userCaches, name: name, url: url, isSelectedByDefault: false, note: "In use by \(app)")
        }
        if kind(of: url) == .directory, !canList(url) {
            return CleanupItem(category: .userCaches, name: name, url: url, isSelectedByDefault: false, note: "Protected by macOS; CareMyMac can’t read it.")
        }
        return CleanupItem(category: .userCaches, name: name, url: url, isSelectedByDefault: true)
    }

    /// The running app whose bundle ID is the folder name or its prefix ("com.example.App.ShipIt"),
    /// or whose name is the folder name ("Dia").
    private static func runningApp(owning folder: String, in running: [String: String]) -> String? {
        let key = folder.lowercased()
        if let name = running[key] { return name }
        var components = key.split(separator: ".")
        while components.count > 2 {
            components.removeLast()
            if let name = running[components.joined(separator: ".")] { return name }
        }
        return running.values.first { $0.lowercased() == key }
    }

    // MARK: - File system

    enum ListingError: Error {
        case missing
        case blocked
        case other
    }

    enum EntryKind {
        case directory
        case file
        case symlink
        case other
    }

    /// Visible, non-symlink children of a folder, as paths under `url` exactly as given (never resolved).
    static func listing(_ url: URL) -> Result<[URL], ListingError> {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch let error as CocoaError {
            if error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return .failure(.missing) }
            if error.code == .fileReadNoPermission || isPermission(error.underlying) { return .failure(.blocked) }
            return .failure(.other)
        } catch {
            return .failure(isPermission(error) ? .blocked : .other)
        }
        let visible = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name -> URL? in
            guard !name.hasPrefix(".") else { return nil }
            let child = url.appending(path: name, directoryHint: .inferFromPath)
            let kind = kind(of: child)
            return kind == .directory || kind == .file ? child : nil
        }
        return .success(visible)
    }

    static func isPermission(_ error: Error?) -> Bool {
        guard let error = error as NSError?, error.domain == NSPOSIXErrorDomain else { return false }
        return error.code == Int(EPERM) || error.code == Int(EACCES)
    }

    /// Kind of the entry itself; symlinks are never resolved.
    static func kind(of url: URL) -> EntryKind? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    private static func canList(_ url: URL) -> Bool {
        guard let dir = opendir(url.path) else { return false }
        closedir(dir)
        return true
    }
}

private extension CocoaError {
    var underlying: Error? { (self as NSError).userInfo[NSUnderlyingErrorKey] as? Error }
}

/// Paths already given to a category. A path overlapping a claimed one (same, inside, or containing) is refused.
private struct Claims {
    private var paths: [String] = []

    mutating func claim(_ url: URL) -> Bool {
        // APFS volumes are case-insensitive by default.
        let path = url.path.lowercased()
        for claimed in paths where claimed == path || claimed.hasPrefix(path + "/") || path.hasPrefix(claimed + "/") {
            return false
        }
        paths.append(path)
        return true
    }
}
