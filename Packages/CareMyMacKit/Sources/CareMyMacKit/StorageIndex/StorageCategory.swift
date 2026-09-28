import Foundation

/// Location-based storage categories. These are CareMyMac's own buckets, not Apple's "System Data".
public enum StorageCategory: String, Sendable, Hashable, Codable, CaseIterable, CodingKeyRepresentable {
    case downloads
    case documentsAndDesktop
    case applications
    case media
    case developer
    case appData
    case caches
    case system
    case other

    public var displayName: String {
        switch self {
        case .downloads: "Downloads"
        case .documentsAndDesktop: "Documents & Desktop"
        case .applications: "Applications"
        case .media: "Media"
        case .developer: "Developer"
        case .appData: "App data"
        case .caches: "Caches"
        case .system: "System"
        case .other: "Other files"
        }
    }

    /// Dense index used by the indexer's fixed-size tallies.
    var index: Int {
        switch self {
        case .downloads: 0
        case .documentsAndDesktop: 1
        case .applications: 2
        case .media: 3
        case .developer: 4
        case .appData: 5
        case .caches: 6
        case .system: 7
        case .other: 8
        }
    }

    static let count = 9

    /// Classifies an absolute, symlink-resolved path. `home` is the user's home folder.
    /// Files inherit the category of their enclosing folder.
    ///
    /// Rules, first match wins:
    /// - Inside home:
    ///   - `~/Library/Caches`, `~/.cache` → caches
    ///   - `~/Library/Developer`, `~/Library/Android` → developer
    ///   - `~/Library/Application Support`, `~/Library/Containers`, `~/Library/Group Containers` → app data
    ///   - `~/Downloads` → downloads; `~/Documents`, `~/Desktop` → documents & desktop
    ///   - `~/Movies`, `~/Music`, `~/Pictures` → media; `~/Applications` → applications
    ///   - project roots (`~/Developer`, `~/dev`, `~/Projects`, `~/code`, `~/src`, `~/repos`, `~/git`,
    ///     `~/workspace`, `~/go`, `~/Android`, …) and toolchain dot-folders (`~/.bun`, `~/.npm`, `~/.cargo`,
    ///     `~/.gradle`, `~/.android`, …) → developer
    ///   - anything under a `node_modules` or `.git` folder that would otherwise be downloads,
    ///     documents & desktop or other → developer
    ///   - everything else → other
    /// - `/Applications` → applications; `/Library/Developer`, `/opt/homebrew`, `/usr/local` → developer
    /// - `/System`, `/Library`, `/private`, `/usr`, `/bin`, `/sbin`, `/cores` → system
    /// - everything else → other
    public static func classify(path: String, home: String) -> StorageCategory {
        if let rel = relative(path, to: home) {
            return classifyInHome(rel)
        }
        if within(path, "/Applications") { return .applications }
        if within(path, "/Library/Developer") || within(path, "/opt/homebrew") || within(path, "/usr/local") {
            return .developer
        }
        for base in systemRoots where within(path, base) { return .system }
        return .other
    }

    private static let systemRoots = ["/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/cores"]

    private static let developerHomeFolders: Set<String> = [
        "developer", "dev", "projects", "code", "src", "source", "repos", "repositories", "git", "github",
        "workspace", "workspaces", "go", "android", "flutter", "anaconda3", "miniconda3", "miniforge3",
    ]

    private static let developerDotFolders: Set<String> = [
        ".bun", ".npm", ".pnpm-store", ".yarn", ".nvm", ".cargo", ".rustup", ".gradle", ".android", ".m2",
        ".pyenv", ".rbenv", ".gem", ".deno", ".expo", ".cocoapods", ".swiftpm", ".docker", ".colima",
        ".orbstack", ".conda", ".pub-cache", ".dartserver", ".konan", ".sdkman", ".volta", ".nuget", ".dotnet",
        ".stack", ".ghcup", ".opam", ".julia", ".vagrant.d", ".minikube", ".kube", ".proto", ".asdf",
    ]

    private static func classifyInHome(_ rel: Substring) -> StorageCategory {
        let first = firstComponent(rel)
        let rest = rel.dropFirst(first.count).drop(while: { $0 == "/" })
        let base: StorageCategory
        switch first.lowercased() {
        case "library":
            let second = firstComponent(rest)
            switch second {
            case "Caches": return .caches
            case "Developer", "Android": return .developer
            case "Application Support", "Containers", "Group Containers": return .appData
            default: base = .other
            }
        case ".cache": return .caches
        case "downloads": base = .downloads
        case "documents", "desktop": base = .documentsAndDesktop
        case "movies", "music", "pictures": return .media
        case "applications": return .applications
        case let name where developerHomeFolders.contains(name) || developerDotFolders.contains(name):
            return .developer
        default: base = .other
        }
        return containsDeveloperComponent(rest) ? .developer : base
    }

    private static func containsDeveloperComponent(_ path: Substring) -> Bool {
        for component in path.split(separator: "/", omittingEmptySubsequences: true)
        where component == "node_modules" || component == ".git" {
            return true
        }
        return false
    }

    private static func firstComponent(_ path: Substring) -> Substring {
        path.prefix(while: { $0 != "/" })
    }

    /// `path` relative to `base` (empty when equal), or nil when outside.
    private static func relative(_ path: String, to base: String) -> Substring? {
        if base == "/" { return path.hasPrefix("/") ? path.dropFirst() : nil }
        guard path.hasPrefix(base) else { return nil }
        let rest = path.dropFirst(base.count)
        if rest.isEmpty { return rest }
        guard rest.first == "/" else { return nil }
        return rest.dropFirst()
    }

    /// True when `path` is `base` or inside it.
    static func within(_ path: String, _ base: String) -> Bool {
        relative(path, to: base) != nil
    }

    /// Enclosing folder of an absolute path; nil for "/".
    static func parentPath(of path: String) -> String? {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return nil }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }
}
