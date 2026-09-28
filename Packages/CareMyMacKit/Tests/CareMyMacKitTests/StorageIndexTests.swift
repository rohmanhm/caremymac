import Foundation
import Testing
@testable import CareMyMacKit

private typealias Dir = StorageIndexResult.MeasuredDirectory

private let MB: Int64 = 1_000_000
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func dir(_ path: String, _ bytes: Int64, unreadable: Int = 0) -> Dir {
    Dir(path: path, category: .other, bytes: bytes, categoryBytes: [.other: bytes], categoryUnreadable: unreadable > 0 ? [.other: unreadable] : [:], measuredAt: epoch)
}

/// Scratch home folder, removed on deinit.
private final class Sandbox {
    let url: URL
    var path: String { url.path }

    init() throws {
        let base = URL(fileURLWithPath: try StorageIndexer.resolve(FileManager.default.temporaryDirectory.path))
        url = base.appendingPathComponent("StorageIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions so removal succeeds.
        if let paths = FileManager.default.subpaths(atPath: url.path) {
            for path in paths { chmod(url.appendingPathComponent(path).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ relative: String, size: Int) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: size).write(to: file)
        return file
    }

    /// Allocated bytes as reported by Foundation, each inode once.
    func expectedAllocated(under relative: String = "") throws -> Int64 {
        let root = relative.isEmpty ? url : url.appendingPathComponent(relative)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .fileResourceIdentifierKey]
        var seen = Set<AnyHashable>()
        var total: Int64 = 0
        for case let item as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })! {
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, let id = values.fileResourceIdentifier as? AnyHashable, seen.insert(id).inserted else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

@Suite struct StorageIndexTests {
    // MARK: Categorization

    @Test(arguments: [
        ("/Users/me/Downloads/a.dmg", StorageCategory.downloads),
        ("/Users/me/Documents/notes", .documentsAndDesktop),
        ("/Users/me/Desktop", .documentsAndDesktop),
        ("/Users/me/Documents/site/node_modules/react", .developer),
        ("/Users/me/Downloads/repo/.git/objects", .developer),
        ("/Users/me/Movies", .media),
        ("/Users/me/Music/Logic", .media),
        ("/Users/me/Pictures/Photos Library.photoslibrary", .media),
        ("/Users/me/Applications/Foo.app", .applications),
        ("/Applications/Xcode.app", .applications),
        ("/Users/me/Library/Developer/Xcode/DerivedData", .developer),
        ("/Library/Developer/CommandLineTools", .developer),
        ("/Users/me/Developer", .developer),
        ("/Users/me/dev/project", .developer),
        ("/Users/me/.bun/install/cache", .developer),
        ("/Users/me/.cargo", .developer),
        ("/Users/me/.android/avd", .developer),
        ("/Users/me/Android/sdk", .developer),
        ("/Users/me/Library/Application Support/Code", .appData),
        ("/Users/me/Library/Containers/com.apple.mail", .appData),
        ("/Users/me/Library/Group Containers/group.x", .appData),
        ("/Users/me/Library/Application Support/Code/node_modules", .appData),
        ("/Users/me/Library/Caches/com.spotify.client", .caches),
        ("/Users/me/Library/Caches/x/node_modules", .caches),
        ("/Users/me/.cache/huggingface", .caches),
        ("/System/Library", .system),
        ("/private/var/db", .system),
        ("/Library/Fonts", .system),
        ("/Users/me/Library", .other),
        ("/Users/me/.codex", .other),
        ("/Users/me", .other),
        ("/Users/meagain/Downloads", .other),
        ("/Users/Shared", .other),
        ("/Volumes/External", .other),
    ])
    func classifiesByLocation(path: String, expected: StorageCategory) {
        #expect(StorageCategory.classify(path: path, home: "/Users/me") == expected)
    }

    // MARK: Folder listing rule

    @Test func listsLeafSignificantFolders() {
        let dirs = [
            dir("/r", 10_000 * MB),
            // Children cover 90% → Library itself is not listed.
            dir("/r/Library", 5_000 * MB),
            dir("/r/Library/Caches", 3_000 * MB),
            dir("/r/Library/Developer", 1_500 * MB),
            // Children cover 60% → both parent and child are listed.
            dir("/r/dev", 2_000 * MB),
            dir("/r/dev/app", 1_200 * MB),
            // Below the 100 MB threshold (1% of total): not listed.
            dir("/r/small", 90 * MB),
            // Atomic: the bundle is listed, its contents never are.
            dir("/r/Big.app", 1_000 * MB),
            dir("/r/Big.app/Contents", 1_000 * MB),
        ]
        let listed = StorageIndexResult.folderListing(directories: dirs, rootPath: "/r", totalMeasured: 10_000 * MB)
        #expect(listed.map(\.path) == ["/r/Library/Caches", "/r/dev", "/r/Library/Developer", "/r/dev/app", "/r/Big.app"])
        #expect(listed.map(\.name) == ["Caches", "dev", "Developer", "app", "Big.app"])
    }

    @Test func listingThresholdCapsAt500MBAndRespectsLimitAndDepth() {
        var dirs = [dir("/r", 1_000_000 * MB)]
        for i in 0..<5 { dirs.append(dir("/r/f\(i)", Int64(600 + i) * MB)) }
        dirs.append(dir("/r/tiny", 400 * MB))
        // A deep chain whose leaf is unreadable; ancestors carry the leaf's unreadable count.
        for path in ["/r/a", "/r/a/b", "/r/a/b/c", "/r/a/b/c/d"] {
            dirs.append(dir(path, 700 * MB, unreadable: 2))
        }
        let all = StorageIndexResult.folderListing(directories: dirs, rootPath: "/r", totalMeasured: 1_000_000 * MB)
        // Depth 4 is beyond maxListedDepth, so the depth-3 folder is the leaf.
        #expect(all.map(\.path) == ["/r/a/b/c", "/r/f4", "/r/f3", "/r/f2", "/r/f1", "/r/f0"])
        #expect(all.first?.hasPartialAccess == true)
        let limited = StorageIndexResult.folderListing(directories: dirs, rootPath: "/r", totalMeasured: 1_000_000 * MB, limit: 2)
        #expect(limited.map(\.path) == ["/r/a/b/c", "/r/f4"])
    }

    // MARK: Indexer

    @Test func measuresAllocatedSizesByCategoryAndCountsHardLinksOnce() async throws {
        let box = try Sandbox()
        try box.file("Downloads/a.bin", size: 300_000)
        try box.file("Documents/b.txt", size: 10)
        try box.file("Documents/site/node_modules/pkg/index.js", size: 50_000)
        try box.file("Library/Caches/c.db", size: 120_000)
        let linked = try box.file("Movies/clip.mov", size: 200_000)
        try FileManager.default.linkItem(at: linked, to: box.url.appendingPathComponent("Movies/clip-link.mov"))
        try box.file("loose.txt", size: 5)
        // Symlinks are not followed: the linked-to tree is outside the root.
        let outside = try Sandbox()
        try outside.file("huge.bin", size: 1_000_000)
        try FileManager.default.createSymbolicLink(at: box.url.appendingPathComponent("outside-link"), withDestinationURL: outside.url)

        let result = try await StorageIndexer().index(root: box.url, home: box.url)

        #expect(result.totalMeasured == (try box.expectedAllocated()))
        #expect(result.total(for: .downloads)?.bytes == (try box.expectedAllocated(under: "Downloads")))
        #expect(result.total(for: .developer)?.bytes == (try box.expectedAllocated(under: "Documents/site/node_modules")))
        #expect(result.total(for: .caches)?.bytes == (try box.expectedAllocated(under: "Library/Caches")))
        #expect(result.total(for: .media)?.bytes == (try box.expectedAllocated(under: "Movies")))
        #expect(result.total(for: .downloads)?.status == .upToDate)
        #expect(result.total(for: .system)?.status == .updatePending)
        #expect(result.total(for: .applications)?.status == .updatePending)
        #expect(result.categories.map(\.category) == StorageCategory.allCases)
        #expect(result.categories.reduce(0) { $0 + $1.bytes } == result.totalMeasured)
        #expect(result.unreadableItemCount == 0)
        #expect(result.directories.first { $0.path == box.path }?.bytes == result.totalMeasured)
    }

    @Test func workerCountDoesNotChangeTheResult() async throws {
        let box = try Sandbox()
        for i in 0..<6 {
            for j in 0..<5 {
                for k in 0..<4 { try box.file("a\(i)/b\(j)/c\(k)/file", size: 100_000 * (i + j + k + 1)) }
            }
            try box.file("a\(i)/top", size: 777)
        }
        var results: [StorageIndexResult] = []
        for workers in [1, 2, 8] {
            var options = StorageIndexer.Options()
            options.maxConcurrentScans = workers
            results.append(try await StorageIndexer(options: options).index(root: box.url, home: box.url))
        }
        #expect(results[0].totalMeasured == (try box.expectedAllocated()))
        let a2 = results[0].directories.first { $0.path == box.path + "/a2" }
        #expect(a2?.bytes == (try box.expectedAllocated(under: "a2")))
        let signature = { (r: StorageIndexResult) in r.directories.map { "\($0.path)=\($0.bytes)" }.sorted() }
        for result in results.dropFirst() {
            #expect(result.categories == results[0].categories)
            #expect(signature(result) == signature(results[0]))
            #expect(result.folders.map(\.path) == results[0].folders.map(\.path))
        }
    }

    @Test func countsUnreadableFoldersAsPartialAccess() async throws {
        let box = try Sandbox()
        try box.file("Downloads/ok.bin", size: 1_100_000)
        try box.file("Downloads/locked/secret.bin", size: 8_192)
        try box.file("Library/Caches/locked/x.bin", size: 8_192)
        chmod(box.url.appendingPathComponent("Downloads/locked").path, 0)
        chmod(box.url.appendingPathComponent("Library/Caches/locked").path, 0)

        let result = try await StorageIndexer().index(root: box.url, home: box.url)

        #expect(result.unreadableItemCount == 2)
        #expect(result.total(for: .downloads)?.status == .partialAccess)
        #expect(result.total(for: .downloads)?.unreadableItemCount == 1)
        #expect(result.total(for: .caches)?.status == .partialAccess)
        #expect(result.total(for: .media)?.status == .updatePending)
        let downloads = result.directories.first { $0.path == box.path + "/Downloads" }
        #expect(downloads?.unreadableItemCount == 1)
        #expect(result.directories.first { $0.path == box.path }?.unreadableItemCount == 2)
    }

    @Test func cancellationThrows() async throws {
        let box = try Sandbox()
        for i in 0..<200 { try box.file("d\(i % 20)/e\(i)/f", size: 10) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StorageIndexer().index(root: box.url, home: box.url)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: Merge

    @Test func mergingARescanMatchesAFreshFullIndex() async throws {
        let box = try Sandbox()
        try box.file("Downloads/a.bin", size: 2_000_000)
        try box.file("Library/Caches/app/blob", size: 3_000_000)
        try box.file("Library/Caches/app/other", size: 1_000_000)
        try box.file("Library/Application Support/X/data", size: 4_000_000)
        try box.file("Library/Caches/locked/y", size: 4_096)
        chmod(box.url.appendingPathComponent("Library/Caches/locked").path, 0)
        let indexer = StorageIndexer()
        let full = try await indexer.index(root: box.url, home: box.url)
        #expect(full.total(for: .caches)?.status == .partialAccess)

        // Change the tree under Library: shrink caches, restore access, grow app data.
        try FileManager.default.removeItem(at: box.url.appendingPathComponent("Library/Caches/app/blob"))
        chmod(box.url.appendingPathComponent("Library/Caches/locked").path, 0o755)
        try box.file("Library/Application Support/X/more", size: 5_000_000)
        try box.file("Library/Caches/app/new", size: 700_000)

        let partial = try await indexer.index(root: box.url.appendingPathComponent("Library"), home: box.url)
        let merged = StorageIndexResult.merge(partial, into: full)
        let fresh = try await indexer.index(root: box.url, home: box.url)

        #expect(merged.rootPath == box.path)
        #expect(merged.date == partial.date)
        #expect(merged.totalMeasured == fresh.totalMeasured)
        #expect(merged.unreadableItemCount == 0)
        #expect(merged.categories == fresh.categories)
        let home = merged.directories.first { $0.path == box.path }
        #expect(home?.bytes == fresh.totalMeasured)
        #expect(home?.unreadableItemCount == 0)
        #expect(Set(merged.directories.map(\.path)) == Set(fresh.directories.map(\.path)))
        #expect(merged.folders.map(\.path) == fresh.folders.map(\.path))
        let downloads = merged.folders.first { $0.path.hasSuffix("/Downloads") }
        #expect(downloads?.measuredAt == full.date)
    }

    @Test func mergeKeepsNeverMeasuredCategoriesPendingAndAddsDisjointRoots() async throws {
        let homeBox = try Sandbox()
        try homeBox.file("Downloads/a", size: 100_000)
        let appsBox = try Sandbox()
        try appsBox.file("Tool/bin", size: 50_000)
        let indexer = StorageIndexer()
        let full = try await indexer.index(root: homeBox.url, home: homeBox.url)
        let other = try await indexer.index(root: appsBox.url, home: homeBox.url)

        let merged = StorageIndexResult.merge(other, into: full)

        #expect(merged.rootPath == homeBox.path)
        #expect(merged.totalMeasured == full.totalMeasured + other.totalMeasured)
        #expect(merged.total(for: .downloads) == full.total(for: .downloads))
        // Temporary folders live under /private, so the disjoint scan is System.
        #expect(merged.total(for: .system)?.bytes == other.totalMeasured)
        #expect(merged.total(for: .system)?.status == .upToDate)
        #expect(merged.total(for: .applications)?.status == .updatePending)
        #expect(merged.total(for: .applications)?.bytes == 0)

        // Rescanning a folder that contains the previous root supersedes it.
        let parent = try await indexer.index(root: homeBox.url.deletingLastPathComponent(), home: homeBox.url)
        let superseded = StorageIndexResult.merge(parent, into: full)
        #expect(superseded.rootPath == parent.rootPath)
        #expect(superseded.totalMeasured == parent.totalMeasured)
        #expect(superseded.categories == parent.categories)
    }

    // MARK: Persistence

    @Test func storeRoundTripsAndReportsMissingFile() async throws {
        let box = try Sandbox()
        try box.file("Downloads/a", size: 5_000)
        let store = StorageIndexStore(url: box.url.appendingPathComponent("CareMyMac/nested/storage-index.json"))
        #expect(try store.load() == nil)
        let result = try await StorageIndexer().index(root: box.url.appendingPathComponent("Downloads"), home: box.url)
        try store.save(result)
        let loaded = try #require(try store.load())
        #expect(loaded == result)
    }
}
