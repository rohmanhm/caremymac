import Foundation
import CareMyMacKit
import Observation

/// Scan state for the Storage page. One instance lives for the whole app session, so switching pages
/// neither cancels a running scan nor drops the last result.
@Observable
@MainActor
final class StorageModel {
    static let shared = StorageModel()

    /// Last finished (and possibly merged) index; nil until the first scan or a saved result loads.
    private(set) var result: StorageIndexResult?
    /// True once the saved result has been read (or found missing).
    private(set) var hasLoaded = false
    /// Folder being indexed right now; nil when idle.
    private(set) var scanningPath: String?
    private(set) var progress: StorageIndexProgress?
    private(set) var errorMessage: String?

    var isScanning: Bool { scanningPath != nil }

    let homeURL = FileManager.default.homeDirectoryForCurrentUser
    private let store: StorageIndexStore
    private var loadTask: Task<Void, Never>?
    private var indexTask: Task<StorageIndexResult, Error>?
    /// Bumped per scan so late progress callbacks from a finished or cancelled run are ignored.
    private var generation = 0

    private init() {
        store = StorageIndexStore(url: Self.storeURL)
    }

    private static var storeURL: URL {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "CareMyMacStorageIndex") {
            return URL(fileURLWithPath: path)
        }
        #endif
        return URL.applicationSupportDirectory
            .appending(path: "CareMyMac", directoryHint: .isDirectory)
            .appending(path: "storage-index.json", directoryHint: .notDirectory)
    }

    /// Reads the saved result once. Decoding happens off the main actor (the file can be a few MB).
    func loadIfNeeded() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let store = store
        let task = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                try store.load()
            }.result
            switch loaded {
            case .success(let saved):
                // A scan that finished while loading is newer than the file.
                if result == nil { result = saved }
            case .failure:
                errorMessage = "The saved storage index couldn’t be read. Scan again to rebuild it."
            }
            hasLoaded = true
            #if DEBUG
            if let path = UserDefaults.standard.string(forKey: "CareMyMacStorageAutoScan") {
                scan(folder: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
            #endif
        }
        loadTask = task
        await task.value
    }

    /// Indexes the home folder and replaces the previous result.
    func scanHome() {
        start(root: homeURL, merging: false)
    }

    /// Re-indexes the folder the current result covers, keeping any other folders merged into it.
    func rescan() {
        guard let result else { return scanHome() }
        start(root: URL(fileURLWithPath: result.rootPath), merging: true)
    }

    /// Indexes one folder and merges it into the previous result (or starts one when there is none).
    func scan(folder: URL) {
        start(root: folder, merging: true)
    }

    func cancel() {
        indexTask?.cancel()
    }

    func dismissError() {
        errorMessage = nil
    }

    private func start(root: URL, merging: Bool) {
        indexTask?.cancel()
        generation += 1
        let generation = generation
        let home = homeURL
        let base = merging ? result : nil
        scanningPath = root.path
        progress = nil
        errorMessage = nil

        // Indexing and merging both run off the main actor; only the finished value hops back.
        let work = Task.detached(priority: .utility) {
            let scanned = try await StorageIndexer().index(root: root, home: home) { progress in
                Task { @MainActor in StorageModel.shared.report(progress, generation: generation) }
            }
            try Task.checkCancellation()
            return base.map { StorageIndexResult.merge(scanned, into: $0) } ?? scanned
        }
        indexTask = work
        Task {
            let outcome = await work.result
            finish(outcome, generation: generation)
        }
    }

    private func report(_ progress: StorageIndexProgress, generation: Int) {
        guard generation == self.generation, isScanning else { return }
        self.progress = progress
    }

    private func finish(_ outcome: Result<StorageIndexResult, Error>, generation: Int) {
        guard generation == self.generation else { return }
        scanningPath = nil
        progress = nil
        switch outcome {
        case .success(let merged):
            result = merged
            let store = store
            Task.detached(priority: .utility) {
                do {
                    try store.save(merged)
                } catch {
                    await MainActor.run { StorageModel.shared.errorMessage = "The scan finished but couldn’t be saved: \(error.localizedDescription)" }
                }
            }
        case .failure(let error):
            if error is CancellationError { return }
            errorMessage = Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        if case StorageIndexError.cannotReadRoot(let path, let code) = error {
            let name = (path as NSString).abbreviatingWithTildeInPath
            if code == EPERM || code == EACCES {
                return "CareMyMac isn’t allowed to read \(name). Grant Full Disk Access, then scan again."
            }
            if code == ENOENT { return "\(name) no longer exists." }
            return "\(name) couldn’t be read (\(String(cString: strerror(code))))."
        }
        return "The scan stopped: \(error.localizedDescription)"
    }
}
