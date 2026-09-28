import Foundation

public enum StorageCategoryStatus: String, Sendable, Hashable, Codable {
    /// Measured with every item readable.
    case upToDate
    /// Not measured by any run that produced this result.
    case updatePending
    /// Measured, but some items in the category could not be read.
    case partialAccess
}

public struct StorageIndexResult: Sendable, Hashable, Codable {
    public struct CategoryTotal: Sendable, Hashable, Codable {
        public var category: StorageCategory
        public var bytes: Int64
        public var status: StorageCategoryStatus
        public var unreadableItemCount: Int

        public init(category: StorageCategory, bytes: Int64, status: StorageCategoryStatus, unreadableItemCount: Int) {
            self.category = category
            self.bytes = bytes
            self.status = status
            self.unreadableItemCount = unreadableItemCount
        }
    }

    /// A row in "Where your space goes".
    public struct FolderEntry: Sendable, Hashable, Codable, Identifiable {
        public var path: String
        public var name: String
        public var category: StorageCategory
        public var bytes: Int64
        public var hasPartialAccess: Bool
        /// When this folder was last measured. Earlier than the result's `date` after a "Choose folder"
        /// merge that did not include this folder.
        public var measuredAt: Date

        public var id: String { path }

        public init(path: String, name: String, category: StorageCategory, bytes: Int64, hasPartialAccess: Bool, measuredAt: Date) {
            self.path = path
            self.name = name
            self.category = category
            self.bytes = bytes
            self.hasPartialAccess = hasPartialAccess
            self.measuredAt = measuredAt
        }
    }

    /// Retained per-folder measurement (subtree totals). `directories` is ancestor-closed up to each scan
    /// root, so it is the tree that folder listing and merging work on. The indexer retains folders of at
    /// least `StorageIndexer.retainedFloor(total:)` bytes, at most `Options.maxRetainedDepth` below the root.
    public struct MeasuredDirectory: Sendable, Hashable, Codable {
        public var path: String
        /// Location category of the folder itself (`StorageCategory.classify`).
        public var category: StorageCategory
        public var bytes: Int64
        /// Subtree bytes split by the category of each file's location; zero entries omitted.
        public var categoryBytes: [StorageCategory: Int64]
        public var categoryUnreadable: [StorageCategory: Int]
        public var measuredAt: Date

        public var unreadableItemCount: Int { categoryUnreadable.values.reduce(0, +) }

        public init(path: String, category: StorageCategory, bytes: Int64, categoryBytes: [StorageCategory: Int64], categoryUnreadable: [StorageCategory: Int], measuredAt: Date) {
            self.path = path
            self.category = category
            self.bytes = bytes
            self.categoryBytes = categoryBytes
            self.categoryUnreadable = categoryUnreadable
            self.measuredAt = measuredAt
        }
    }

    /// Time of the latest run contributing to this result.
    public var date: Date
    /// Folder the index covers. After merging a rescan of an unrelated folder, `directories` also holds
    /// that folder's tree; totals include it.
    public var rootPath: String
    public var totalMeasured: Int64
    public var unreadableItemCount: Int
    /// One entry per `StorageCategory`, in `allCases` order.
    public var categories: [CategoryTotal]
    /// "Where your space goes", sorted by size descending. See `folderListing`.
    public var folders: [FolderEntry]
    public var directories: [MeasuredDirectory]

    public init(date: Date, rootPath: String, totalMeasured: Int64, unreadableItemCount: Int, categories: [CategoryTotal], folders: [FolderEntry], directories: [MeasuredDirectory]) {
        self.date = date
        self.rootPath = rootPath
        self.totalMeasured = totalMeasured
        self.unreadableItemCount = unreadableItemCount
        self.categories = categories
        self.folders = folders
        self.directories = directories
    }

    public func total(for category: StorageCategory) -> CategoryTotal? {
        categories.first { $0.category == category }
    }
}

// MARK: - Folder listing rule

extension StorageIndexResult {
    public static let defaultFolderLimit = 200
    /// Folders at or above this size are always significant.
    public static let significantBytes: Int64 = 500_000_000
    /// Folders at or above this share of the total are significant (for small scans).
    public static let significantShare = 0.01
    /// A folder whose listed descendants cover at least this share of it is represented by them instead.
    public static let coveredShare = 0.7
    /// Deepest folder, counted from its scan root, that can be listed.
    public static let maxListedDepth = 3

    /// "Where your space goes":
    /// 1. A folder is *significant* when its size is at least `min(500 MB, 1% of totalMeasured)`.
    /// 2. The *coverage* of a folder is the summed size of its nearest listed descendants.
    /// 3. A folder is listed when it is significant, is not `rootPath`, is at most `maxListedDepth` below
    ///    its scan root, and its coverage is below 70% of its size. An ancestor therefore appears next to
    ///    listed descendants only when at least 30% of it lies outside them.
    /// 4. `/System`, app bundles (`*.app`), `node_modules` and `.git` folders are atomic: nothing inside
    ///    them is listed.
    /// 5. The `limit` largest listed folders are returned, by size descending (ties by path).
    public static func folderListing(directories: [MeasuredDirectory], rootPath: String, totalMeasured: Int64, limit: Int = defaultFolderLimit) -> [FolderEntry] {
        guard limit > 0, !directories.isEmpty else { return [] }
        let threshold = max(1, min(significantBytes, Int64((Double(totalMeasured) * significantShare).rounded(.up))))
        let byPath = Dictionary(directories.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })

        var children: [String: [String]] = [:]
        var scanRoots: [String] = []
        for path in byPath.keys {
            if let parent = nearestRetainedAncestor(of: path, in: byPath) {
                children[parent, default: []].append(path)
            } else {
                scanRoots.append(path)
            }
        }

        var listed: [MeasuredDirectory] = []
        // Post-order; returns the bytes covered by listed folders in the subtree, the folder included.
        func visit(_ dir: MeasuredDirectory, depth: Int) -> Int64 {
            var covered: Int64 = 0
            if !isAtomic(dir.path) {
                for child in children[dir.path] ?? [] {
                    covered += visit(byPath[child]!, depth: depth + 1)
                }
            }
            guard dir.path != rootPath,
                  depth <= maxListedDepth,
                  dir.bytes >= threshold,
                  Double(covered) < coveredShare * Double(dir.bytes)
            else { return covered }
            listed.append(dir)
            return dir.bytes
        }
        for root in scanRoots { _ = visit(byPath[root]!, depth: 0) }

        listed.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        return listed.prefix(limit).map { dir in
            FolderEntry(
                path: dir.path,
                name: dir.path == "/" ? "/" : String(dir.path[dir.path.index(after: dir.path.lastIndex(of: "/")!)...]),
                category: dir.category,
                bytes: dir.bytes,
                hasPartialAccess: dir.unreadableItemCount > 0,
                measuredAt: dir.measuredAt
            )
        }
    }

    private static func nearestRetainedAncestor(of path: String, in byPath: [String: MeasuredDirectory]) -> String? {
        var current = path
        while let parent = StorageCategory.parentPath(of: current) {
            if byPath[parent] != nil { return parent }
            current = parent
        }
        return nil
    }

    private static func isAtomic(_ path: String) -> Bool {
        if path == "/System" { return true }
        guard let slash = path.lastIndex(of: "/") else { return false }
        let name = path[path.index(after: slash)...]
        return name.hasSuffix(".app") || name == "node_modules" || name == ".git"
    }
}

// MARK: - Merging a "Choose folder" rescan

extension StorageIndexResult {
    /// Merges a rescan of one folder (`partial.rootPath`) into a previous result.
    ///
    /// - Retained folders at or under the partial root are replaced by the partial's folders.
    /// - The earlier measurement of the partial root is the sum of the outermost retained folders inside
    ///   it. That is exact when the root itself was retained; a folder below the retention floor had no
    ///   retained record, so its earlier (sub-floor) size cannot be subtracted.
    /// - Retained ancestors, the total, category totals and unreadable counts move by `new − old`.
    /// - A category measured by either run gets its status from the merged unreadable count
    ///   (`partialAccess` or `upToDate`); a category measured by neither stays `updatePending`.
    /// - The partial root replaces `rootPath` when it contains it. `date` becomes the partial's.
    public static func merge(_ partial: StorageIndexResult, into full: StorageIndexResult, folderLimit: Int = defaultFolderLimit) -> StorageIndexResult {
        let root = partial.rootPath
        let replaced = full.directories.filter { StorageCategory.within($0.path, root) }
        let replacedPaths = Set(replaced.map(\.path))
        let outermost = replaced.filter { dir in
            var current = dir.path
            while current != root, let parent = StorageCategory.parentPath(of: current) {
                if replacedPaths.contains(parent) { return false }
                current = parent
            }
            return true
        }

        var oldBytes: [StorageCategory: Int64] = [:]
        var oldUnreadable: [StorageCategory: Int] = [:]
        for dir in outermost {
            oldBytes.merge(dir.categoryBytes, uniquingKeysWith: +)
            oldUnreadable.merge(dir.categoryUnreadable, uniquingKeysWith: +)
        }
        let newRoot = partial.directories.first { $0.path == root }
        let newBytes = newRoot?.categoryBytes ?? [:]
        let newUnreadable = newRoot?.categoryUnreadable ?? [:]
        func bytesDelta(_ category: StorageCategory) -> Int64 { (newBytes[category] ?? 0) - (oldBytes[category] ?? 0) }
        func unreadableDelta(_ category: StorageCategory) -> Int { (newUnreadable[category] ?? 0) - (oldUnreadable[category] ?? 0) }

        var directories: [MeasuredDirectory] = []
        directories.reserveCapacity(full.directories.count - replaced.count + partial.directories.count)
        for var dir in full.directories where !replacedPaths.contains(dir.path) {
            if StorageCategory.within(root, dir.path) {
                for category in StorageCategory.allCases {
                    let delta = bytesDelta(category)
                    dir.bytes += delta
                    dir.categoryBytes[category] = nonZero((dir.categoryBytes[category] ?? 0) + delta)
                    dir.categoryUnreadable[category] = nonZero((dir.categoryUnreadable[category] ?? 0) + unreadableDelta(category))
                }
            }
            directories.append(dir)
        }
        directories.append(contentsOf: partial.directories)

        let categories = StorageCategory.allCases.map { category -> CategoryTotal in
            let previous = full.total(for: category)
            let bytes = (previous?.bytes ?? 0) + bytesDelta(category)
            let unreadable = (previous?.unreadableItemCount ?? 0) + unreadableDelta(category)
            let measured = [previous, partial.total(for: category)].contains { $0.map { $0.status != .updatePending } ?? false }
            let status: StorageCategoryStatus = measured ? (unreadable > 0 ? .partialAccess : .upToDate) : .updatePending
            return CategoryTotal(category: category, bytes: bytes, status: status, unreadableItemCount: unreadable)
        }

        let totalMeasured = full.totalMeasured + StorageCategory.allCases.reduce(0) { $0 + bytesDelta($1) }
        let rootPath = StorageCategory.within(full.rootPath, root) ? root : full.rootPath
        return StorageIndexResult(
            date: partial.date,
            rootPath: rootPath,
            totalMeasured: totalMeasured,
            unreadableItemCount: full.unreadableItemCount + StorageCategory.allCases.reduce(0) { $0 + unreadableDelta($1) },
            categories: categories,
            folders: folderListing(directories: directories, rootPath: rootPath, totalMeasured: totalMeasured, limit: folderLimit),
            directories: directories
        )
    }

    private static func nonZero<T: BinaryInteger>(_ value: T) -> T? { value == 0 ? nil : value }
}
