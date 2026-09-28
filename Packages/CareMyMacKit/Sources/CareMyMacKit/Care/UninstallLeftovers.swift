import Foundation

/// A file or folder in the user’s Library that belongs to an app.
public struct UninstallLeftover: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case applicationSupport, caches, container, groupContainer, preferences, savedState, logs
        case httpStorage, webKit, cookies, launchAgent, applicationScripts

        public var label: String {
            switch self {
            case .applicationSupport: "Application Support"
            case .caches: "Caches"
            case .container: "Container"
            case .groupContainer: "Group Container"
            case .preferences: "Preferences"
            case .savedState: "Saved State"
            case .logs: "Logs"
            case .httpStorage: "HTTP Storage"
            case .webKit: "WebKit Data"
            case .cookies: "Cookies"
            case .launchAgent: "Launch Agent"
            case .applicationScripts: "Application Scripts"
            }
        }
    }

    public var id: String { url.path }
    public let url: URL
    public let kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

/// Result of a leftover search.
public struct UninstallLeftoverScan: Sendable, Hashable {
    public var leftovers: [UninstallLeftover]
    /// Library folders that couldn’t be listed because macOS denied access (Full Disk Access is off).
    public var deniedFolders: [String]

    public init(leftovers: [UninstallLeftover], deniedFolders: [String]) {
        self.leftovers = leftovers
        self.deniedFolders = deniedFolders
    }
}

/// Finds an app’s leftovers in `~/Library` by exact bundle ID or exact app name, compared case-insensitively.
/// Names never match by prefix or substring, so “Code” doesn’t claim “Code Helper” or `com.microsoft.VSCodeInsiders`.
public enum UninstallLeftoverFinder {
    public static func leftovers(for app: InstalledApp, home: URL) throws -> UninstallLeftoverScan {
        try leftovers(bundleIdentifiers: app.allBundleIdentifiers, names: app.names, home: home)
    }

    public static func leftovers(bundleIdentifiers: [String], names: [String], home: URL) throws -> UninstallLeftoverScan {
        let ids = Set(bundleIdentifiers.map { $0.lowercased() }.filter { !$0.isEmpty })
        let names = Set(names.map { $0.lowercased() }.filter { !$0.isEmpty && $0 != "." && $0 != ".." })
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        var found: [UninstallLeftover] = []
        var seen = Set<String>()
        var denied: [String] = []

        func scan(_ folder: String, _ kind: UninstallLeftover.Kind, _ matches: (String) -> Bool) throws {
            try Task.checkCancellation()
            let url = library.appending(path: folder, directoryHint: .isDirectory)
            let entries: [String]
            do {
                entries = try FileManager.default.contentsOfDirectory(atPath: url.path)
            } catch {
                if isPermissionDenied(error) { denied.append(url.path) }
                return
            }
            for entry in entries.sorted() where matches(entry.lowercased()) {
                let item = url.appending(path: entry, directoryHint: .notDirectory)
                if seen.insert(item.path).inserted { found.append(UninstallLeftover(url: item, kind: kind)) }
            }
        }

        let idOrName: (String) -> Bool = { ids.contains($0) || names.contains($0) }
        let exactID: (String) -> Bool = { ids.contains($0) }
        func idWith(suffix: String) -> (String) -> Bool {
            { $0.hasSuffix(suffix) && ids.contains(String($0.dropLast(suffix.count))) }
        }

        try scan("Application Support", .applicationSupport, idOrName)
        try scan("Caches", .caches, exactID)
        try scan("Containers", .container, exactID)
        // Group containers are named after the ID or a team/group prefix plus the ID: “group.com.x”, “ABCDE12345.com.x”.
        try scan("Group Containers", .groupContainer) { entry in
            ids.contains(entry) || ids.contains { entry.hasSuffix(".\($0)") }
        }
        try scan("Preferences", .preferences, idWith(suffix: ".plist"))
        // ByHost preferences add one host token: “com.x.<UUID>.plist”. A longer ID (“com.x.other.<UUID>”) isn’t ours.
        try scan("Preferences/ByHost", .preferences) { entry in
            guard entry.hasSuffix(".plist") else { return false }
            let stem = entry.dropLast(".plist".count)
            guard let dot = stem.lastIndex(of: "."), stem.index(after: dot) < stem.endIndex else { return false }
            return ids.contains(String(stem[..<dot]))
        }
        try scan("Saved Application State", .savedState, idWith(suffix: ".savedstate"))
        try scan("Logs", .logs, idOrName)
        try scan("HTTPStorages", .httpStorage) { ids.contains($0) || idWith(suffix: ".binarycookies")($0) }
        try scan("WebKit", .webKit, exactID)
        try scan("Cookies", .cookies, idWith(suffix: ".binarycookies"))
        // Launch agent labels extend the app’s ID: “com.x.plist”, “com.x.updater.plist”.
        try scan("LaunchAgents", .launchAgent) { entry in
            entry.hasSuffix(".plist") && ids.contains { entry == "\($0).plist" || entry.hasPrefix("\($0).") }
        }
        try scan("Application Scripts", .applicationScripts, exactID)

        return UninstallLeftoverScan(leftovers: found, deniedFolders: denied)
    }

    /// True for EPERM/EACCES and their Cocoa equivalents: the item exists but macOS won’t let CareMyMac read it.
    public static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoPermission.rawValue || error.code == CocoaError.fileWriteNoPermission.rawValue {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }

    /// True when a leftover folder exists but its contents can’t be listed, so its size is incomplete.
    public static func isUnreadable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return false }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return false
        } catch {
            return isPermissionDenied(error)
        }
    }
}
