import Darwin
import Dispatch
import Foundation
import Synchronization

public struct StorageIndexProgress: Sendable, Hashable {
    /// Files and folders seen so far.
    public var itemsScanned: Int
    public var bytesMeasured: Int64
    public var unreadableItemCount: Int
    /// Folder most recently listed by the reporting worker.
    public var currentFolder: String

    public init(itemsScanned: Int, bytesMeasured: Int64, unreadableItemCount: Int, currentFolder: String) {
        self.itemsScanned = itemsScanned
        self.bytesMeasured = bytesMeasured
        self.unreadableItemCount = unreadableItemCount
        self.currentFolder = currentFolder
    }
}

public enum StorageIndexError: Error, Equatable {
    case cannotReadRoot(path: String, errno: Int32)
}

/// Measures allocated file sizes under a folder, bucketed by `StorageCategory`.
///
/// - Uses `getattrlistbulk` (allocated size of all forks, like `totalFileAllocatedSize`).
/// - A task group of `Options.maxConcurrentScans` workers, each on a dispatch thread (the cooperative
///   pool is never blocked), walks depth-first and hands subfolders to idle workers, so one huge folder
///   does not serialize the scan. Subtree totals are reduced bottom-up as folders finish.
/// - Never follows symlinks, never descends into other volumes (the firmlinked Data volume counts as the
///   same volume when indexing "/"), and skips `/System/Volumes/Data` unless the root is inside it, so
///   "/" is counted once.
/// - Hard-linked files are counted once. Dataless (cloud-evicted) folders are not descended.
/// - Items that fail with EPERM/EACCES are counted in `unreadableItemCount`; their folders report
///   partial access.
/// - Task cancellation stops the walk promptly and throws `CancellationError`.
public final class StorageIndexer: Sendable {
    public struct Options: Sendable {
        public var folderLimit = StorageIndexResult.defaultFolderLimit
        /// Deepest folder, counted from the root, whose measurement is retained in `directories`.
        public var maxRetainedDepth = 8
        public var maxConcurrentScans = max(2, ProcessInfo.processInfo.activeProcessorCount)
        public var qos: DispatchQoS.QoSClass = .utility

        public init() {}
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Folders smaller than this are never retained while walking.
    static let walkFloor: Int64 = 1 << 20

    /// Retention floor for a finished index: 1 MB to 16 MB, 0.1% of the total in between.
    public static func retainedFloor(total: Int64) -> Int64 {
        max(walkFloor, min(16 << 20, total / 1000))
    }

    public func index(root: URL, home: URL, progress: @escaping @Sendable (StorageIndexProgress) -> Void = { _ in }) async throws -> StorageIndexResult {
        let rootPath = try Self.resolve(root.path)
        let homePath = (try? Self.resolve(home.path)) ?? home.standardizedFileURL.path

        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else {
            throw StorageIndexError.cannotReadRoot(path: rootPath, errno: errno)
        }
        var devices = [rootStat.st_dev]
        let dataVolume = "/System/Volumes/Data"
        if rootPath == "/" {
            var dataStat = stat()
            if lstat(dataVolume, &dataStat) == 0, !devices.contains(dataStat.st_dev) { devices.append(dataStat.st_dev) }
        }
        let rootNode = ScanNode(path: rootPath, depth: 0, category: StorageCategory.classify(path: rootPath, home: homePath), parent: nil)
        let context = ScanContext(
            home: homePath,
            devices: devices,
            skippedPaths: StorageCategory.within(rootPath, dataVolume) ? [] : [dataVolume],
            maxRetainedDepth: options.maxRetainedDepth,
            root: rootNode,
            progress: progress
        )

        let queue = DispatchQueue.global(qos: options.qos)
        let workers = max(1, options.maxConcurrentScans)
        let records = await withTaskCancellationHandler {
            await withTaskGroup(of: [DirectoryRecord].self) { group in
                for _ in 0..<workers {
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            queue.async { continuation.resume(returning: DirectoryWalker(context: context).run()) }
                        }
                    }
                }
                var records: [DirectoryRecord] = []
                for await part in group { records.append(contentsOf: part) }
                return records
            }
        } onCancel: {
            context.cancel()
        }
        guard let rootTally = context.rootTally, !Task.isCancelled else { throw CancellationError() }

        let total = rootTally.totalBytes
        let floor = Self.retainedFloor(total: total)
        let finished = Date()
        let directories = records
            .filter { $0.depth == 0 || $0.tally.totalBytes >= floor }
            .map { $0.measured(at: finished) }
        let categories = StorageCategory.allCases.map { category in
            let unreadable = rootTally.unreadable[category.index]
            let status: StorageCategoryStatus = rootTally.saw(category) ? (unreadable > 0 ? .partialAccess : .upToDate) : .updatePending
            return StorageIndexResult.CategoryTotal(category: category, bytes: rootTally.bytes[category.index], status: status, unreadableItemCount: unreadable)
        }
        progress(StorageIndexProgress(itemsScanned: context.items.load(ordering: .relaxed), bytesMeasured: total, unreadableItemCount: rootTally.totalUnreadable, currentFolder: rootPath))
        return StorageIndexResult(
            date: finished,
            rootPath: rootPath,
            totalMeasured: total,
            unreadableItemCount: rootTally.totalUnreadable,
            categories: categories,
            folders: StorageIndexResult.folderListing(directories: directories, rootPath: rootPath, totalMeasured: total, limit: options.folderLimit),
            directories: directories
        )
    }

    static func resolve(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw StorageIndexError.cannotReadRoot(path: path, errno: errno)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Scan plumbing

struct Tally: Sendable {
    var bytes = InlineArray<9, Int64>(repeating: 0)
    var unreadable = InlineArray<9, Int>(repeating: 0)
    var seenMask: UInt16 = 0

    var totalBytes: Int64 {
        var sum: Int64 = 0
        for i in bytes.indices { sum += bytes[i] }
        return sum
    }

    var totalUnreadable: Int {
        var sum = 0
        for i in unreadable.indices { sum += unreadable[i] }
        return sum
    }

    func saw(_ category: StorageCategory) -> Bool { seenMask & (1 << category.index) != 0 }

    mutating func add(_ other: Tally) {
        for i in bytes.indices {
            bytes[i] += other.bytes[i]
            unreadable[i] += other.unreadable[i]
        }
        seenMask |= other.seenMask
    }
}

struct DirectoryRecord: Sendable {
    var path: String
    var depth: Int
    var category: StorageCategory
    var tally: Tally

    func measured(at date: Date) -> StorageIndexResult.MeasuredDirectory {
        var bytes: [StorageCategory: Int64] = [:]
        var unreadable: [StorageCategory: Int] = [:]
        for category in StorageCategory.allCases {
            if tally.bytes[category.index] != 0 { bytes[category] = tally.bytes[category.index] }
            if tally.unreadable[category.index] != 0 { unreadable[category] = tally.unreadable[category.index] }
        }
        return .init(path: path, category: category, bytes: tally.totalBytes, categoryBytes: bytes, categoryUnreadable: unreadable, measuredAt: date)
    }
}

/// A folder in flight. Its subtree tally is complete once the folder is listed and every subfolder has
/// finished; the last one to finish reports the total to the parent.
final class ScanNode: Sendable {
    let path: String
    let depth: Int
    let category: StorageCategory
    let parent: ScanNode?
    /// Unfinished work: 1 for the folder's own listing plus one per unfinished subfolder.
    private let state = Mutex<(tally: Tally, pending: Int)>((Tally(), 1))

    init(path: String, depth: Int, category: StorageCategory, parent: ScanNode?) {
        self.path = path
        self.depth = depth
        self.category = category
        self.parent = parent
    }

    /// Call before publishing the subfolders.
    func expect(subfolders: Int) {
        state.withLock { $0.pending += subfolders }
    }

    /// Adds `tally` and retires one unit of pending work; returns the subtree total when none remain.
    func retire(adding tally: Tally) -> Tally? {
        state.withLock { state in
            state.tally.add(tally)
            state.pending -= 1
            return state.pending == 0 ? state.tally : nil
        }
    }
}

private struct FileKey: Hashable {
    var device: Int32
    var id: UInt64
}

final class ScanContext: @unchecked Sendable {
    let home: String
    let devices: [dev_t]
    let skippedPaths: Set<String>
    let maxRetainedDepth: Int
    let progress: @Sendable (StorageIndexProgress) -> Void

    let cancelled = Atomic<Bool>(false)
    let items = Atomic<Int>(0)
    private let bytes = Atomic<Int64>(0)
    private let unreadable = Atomic<Int>(0)
    private let lastReport = Atomic<UInt64>(0)
    private let hardLinks = Mutex<Set<FileKey>>([])

    /// Workers blocked in `take()`; busy workers share subfolders while this is non-zero.
    let idleWorkers = Atomic<Int>(0)
    private let condition = NSCondition()
    // Guarded by `condition`.
    private var shared: [ScanNode]
    private var stopped = false
    private var finalTally: Tally?

    init(home: String, devices: [dev_t], skippedPaths: Set<String>, maxRetainedDepth: Int, root: ScanNode, progress: @escaping @Sendable (StorageIndexProgress) -> Void) {
        self.home = home
        self.devices = devices
        self.skippedPaths = skippedPaths
        self.maxRetainedDepth = maxRetainedDepth
        self.progress = progress
        shared = [root]
    }

    /// Root subtree total; nil unless the walk finished.
    var rootTally: Tally? {
        condition.lock()
        defer { condition.unlock() }
        return finalTally
    }

    /// Next shared folder, waiting while other workers may still share some; nil once the walk is over.
    func take() -> ScanNode? {
        condition.lock()
        defer { condition.unlock() }
        while shared.isEmpty, !stopped {
            idleWorkers.add(1, ordering: .relaxed)
            condition.wait()
            idleWorkers.subtract(1, ordering: .relaxed)
        }
        return stopped ? nil : shared.popLast()
    }

    func share(_ nodes: [ScanNode]) {
        condition.lock()
        shared.append(contentsOf: nodes)
        condition.unlock()
        condition.broadcast()
    }

    func finish(with tally: Tally) {
        condition.lock()
        finalTally = tally
        stopped = true
        condition.unlock()
        condition.broadcast()
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        condition.lock()
        stopped = true
        condition.unlock()
        condition.broadcast()
    }

    /// True the first time a hard-linked file is seen.
    fileprivate func claim(_ key: FileKey) -> Bool {
        hardLinks.withLock { $0.insert(key).inserted }
    }

    func flush(items: Int, bytes: Int64, unreadable: Int, folder: String) {
        let totalItems = self.items.add(items, ordering: .relaxed).newValue
        let totalBytes = self.bytes.add(bytes, ordering: .relaxed).newValue
        let totalUnreadable = self.unreadable.add(unreadable, ordering: .relaxed).newValue
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let last = lastReport.load(ordering: .relaxed)
        guard now &- last >= 200_000_000,
              lastReport.compareExchange(expected: last, desired: now, ordering: .relaxed).exchanged
        else { return }
        progress(StorageIndexProgress(itemsScanned: totalItems, bytesMeasured: totalBytes, unreadableItemCount: totalUnreadable, currentFolder: folder))
    }
}

/// One scan worker. Runs on a dispatch thread until the walk finishes or is cancelled.
final class DirectoryWalker {
    private static let bufferSize = 256 * 1024
    private static let datalessFlag: UInt32 = 0x4000_0000 // SF_DATALESS
    private static let objectTypeRegular: UInt32 = 1 // VREG
    private static let objectTypeDirectory: UInt32 = 2 // VDIR

    private let context: ScanContext
    private let buffer: UnsafeMutableRawPointer
    private var records: [DirectoryRecord] = []
    private var stack: [ScanNode] = []
    private var pendingItems = 0
    private var pendingBytes: Int64 = 0
    private var pendingUnreadable = 0

    init(context: ScanContext) {
        self.context = context
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
    }

    deinit { buffer.deallocate() }

    func run() -> [DirectoryRecord] {
        while let node = stack.popLast() ?? context.take() {
            if context.cancelled.load(ordering: .relaxed) { break }
            visit(node)
        }
        flush(folder: "")
        return records
    }

    private func visit(_ node: ScanNode) {
        var tally = Tally()
        tally.seenMask |= 1 << node.category.index
        let subfolders = list(node.path, category: node.category, into: &tally).map {
            ScanNode(path: $0.path, depth: node.depth + 1, category: $0.category, parent: node)
        }
        if pendingItems >= 4096 { flush(folder: node.path) }
        if !subfolders.isEmpty {
            node.expect(subfolders: subfolders.count)
            if context.idleWorkers.load(ordering: .relaxed) > 0 {
                context.share(subfolders)
            } else {
                stack.append(contentsOf: subfolders)
            }
        }
        // Retire the listing; finishing folders cascade their totals upward.
        var current = node
        var finished = current.retire(adding: tally)
        while let total = finished {
            if current.depth == 0 || (current.depth <= context.maxRetainedDepth && total.totalBytes >= StorageIndexer.walkFloor) {
                records.append(DirectoryRecord(path: current.path, depth: current.depth, category: current.category, tally: total))
            }
            guard let parent = current.parent else {
                context.finish(with: total)
                return
            }
            current = parent
            finished = parent.retire(adding: total)
        }
    }

    private func flush(folder: String) {
        guard pendingItems > 0 || pendingBytes > 0 || pendingUnreadable > 0 else { return }
        context.flush(items: pendingItems, bytes: pendingBytes, unreadable: pendingUnreadable, folder: folder)
        pendingItems = 0
        pendingBytes = 0
        pendingUnreadable = 0
    }

    private func markUnreadable(_ category: StorageCategory, in tally: inout Tally) {
        tally.unreadable[category.index] += 1
        pendingUnreadable += 1
    }

    /// Adds the folder's own files to `tally` and returns the subfolders to descend into.
    private func list(_ path: String, category: StorageCategory, into tally: inout Tally) -> [(path: String, category: StorageCategory)] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == EACCES || errno == EPERM { markUnreadable(category, in: &tally) }
            return []
        }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        let prefix = path == "/" ? "/" : path + "/"
        var children: [(path: String, category: StorageCategory)] = []
        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EACCES || errno == EPERM { markUnreadable(category, in: &tally) }
                break
            }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.load(as: UInt32.self))
                defer { entry += length }
                pendingItems += 1
                var field = entry + MemoryLayout<UInt32>.size
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if error != 0 {
                        if error == EACCES || error == EPERM { markUnreadable(category, in: &tally) }
                        continue
                    }
                }
                let nameField = field
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 { field += MemoryLayout<attrreference_t>.size }
                var device: dev_t = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                    device = field.loadUnaligned(as: dev_t.self)
                    field += MemoryLayout<dev_t>.size
                }
                var objectType: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objectType = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var flags: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
                    flags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var fileID: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }

                if objectType == Self.objectTypeDirectory {
                    guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0,
                          context.devices.contains(device),
                          flags & Self.datalessFlag == 0
                    else { continue }
                    let reference = nameField.loadUnaligned(as: attrreference_t.self)
                    let name = String(cString: (nameField + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    let childPath = prefix + name
                    if context.skippedPaths.contains(childPath) { continue }
                    children.append((childPath, StorageCategory.classify(path: childPath, home: context.home)))
                    continue
                }

                var linkCount: UInt32 = 1
                if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                    linkCount = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                guard returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 else { continue }
                let allocated = field.loadUnaligned(as: off_t.self)
                if linkCount > 1, objectType == Self.objectTypeRegular,
                   !context.claim(FileKey(device: device, id: fileID)) {
                    continue
                }
                tally.bytes[category.index] += allocated
                pendingBytes += allocated
            }
        }
        return children
    }
}
