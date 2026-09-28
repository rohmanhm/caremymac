import Foundation
import CareMyMacKit
import Observation

/// Scan, selection and removal state for the Cleanup page. Owned by the page: leaving the page cancels a scan,
/// and coming back to an unfinished scan starts it again.
@Observable
@MainActor
final class CleanupModel {
    enum Activity: Equatable {
        case idle
        case discovering
        case measuring
        case measuringTrash
        case movingToTrash
        case emptyingTrash
    }

    enum TrashState: Equatable {
        case unknown
        case needsFullDiskAccess
        /// Top-level item count; bytes is nil until measured.
        case contents(count: Int, bytes: Int64?)
    }

    struct Removal: Identifiable {
        let id = UUID()
        let urls: [URL]
        let bytes: Int64
    }

    struct FailureReport: Identifiable {
        let id = UUID()
        let title: String
        let failures: [CareFailure]
    }

    private(set) var items: [CleanupItem] = []
    /// Allocated size by item ID. Survives a rescan so rows keep their last size until measured again.
    private(set) var sizes: [String: Int64] = [:]
    var selection: Set<String> = []
    private(set) var blocked: Set<CleanupCategory> = []
    private(set) var trash: TrashState = .unknown
    private(set) var activity: Activity = .idle
    /// Items listed by the current scan that haven't been measured yet.
    private(set) var unmeasured: Set<String> = []
    /// True once a scan has listed the categories.
    private(set) var hasListed = false
    var failureReport: FailureReport?

    let home = FileManager.default.homeDirectoryForCurrentUser

    private var isComplete = false
    private var isVisible = false
    private var knownIDs: Set<String> = []
    private var scanTask: Task<Void, Never>?
    /// Bumped per scan so late size reports from a cancelled run are ignored.
    private var generation = 0

    var isScanning: Bool { activity == .discovering || activity == .measuring || activity == .measuringTrash }
    var isBusy: Bool { activity != .idle }

    var selectedItems: [CleanupItem] { items.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + (sizes[$1.id] ?? 0) } }

    /// Category being measured right now, for progress.
    var measuringCategory: CleanupCategory? {
        guard activity == .measuring else { return nil }
        return items.first { unmeasured.contains($0.id) }?.category
    }

    func items(in category: CleanupCategory) -> [CleanupItem] {
        items.filter { $0.category == category }
    }

    func appear() {
        isVisible = true
        if !isComplete, !isBusy { scan() }
    }

    func disappear() {
        isVisible = false
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        generation += 1
        activity = .idle
    }

    func scan() {
        scanTask?.cancel()
        generation += 1
        let generation = generation
        isComplete = false
        activity = .discovering
        let environment = CleanupEnvironment.current()
        scanTask = Task {
            let (discovery, listing) = await Task.detached(priority: .userInitiated) {
                (CleanupScanner.discover(environment), CleanupTrash.list(home: environment.home))
            }.value
            guard generation == self.generation else { return }
            apply(discovery, listing)

            activity = .measuring
            do {
                try await CleanupScanner.measure(discovery.items.map(\.url)) { url, size in
                    await self.record(size, for: url.path, generation: generation)
                }
                if case .contents(let children) = listing, !children.isEmpty {
                    guard generation == self.generation else { return }
                    activity = .measuringTrash
                    let total = TrashTotal()
                    try await CleanupScanner.measure(children) { _, size in await total.add(size) }
                    let bytes = await total.bytes
                    guard generation == self.generation else { return }
                    trash = .contents(count: children.count, bytes: bytes)
                }
            } catch {
                // Cancelled: `disappear()` or a newer scan already reset the state.
                return
            }
            guard generation == self.generation else { return }
            activity = .idle
            isComplete = true
        }
    }

    /// The current selection, for the confirmation dialog.
    func selectedRemoval() -> Removal? {
        let selected = selectedItems
        guard !selected.isEmpty else { return nil }
        return Removal(urls: selected.map(\.url), bytes: selectedBytes)
    }

    func moveToTrash(_ removal: Removal) {
        guard !isBusy else { return }
        activity = .movingToTrash
        let urls = removal.urls
        Task {
            let failures = await Task.detached(priority: .userInitiated) { CareFiles.moveToTrash(urls) }.value
            finishChange(failures: failures, title: "Some items couldn’t be moved to the Trash")
        }
    }

    func emptyTrash() {
        guard !isBusy else { return }
        activity = .emptyingTrash
        let home = home
        Task {
            let failures = await Task.detached(priority: .userInitiated) { CleanupTrash.empty(home: home) }.value
            finishChange(failures: failures, title: "Some items couldn’t be deleted")
        }
    }

    private func finishChange(failures: [CareFailure], title: String) {
        activity = .idle
        if !failures.isEmpty {
            failureReport = FailureReport(title: title, failures: failures)
        }
        if isVisible {
            scan()
        } else {
            isComplete = false
        }
    }

    private func apply(_ discovery: CleanupDiscovery, _ listing: CleanupTrash.Listing) {
        let ids = discovery.items.map(\.id)
        let previous = selection
        selection = Set(discovery.items.filter { knownIDs.contains($0.id) ? previous.contains($0.id) : $0.isSelectedByDefault }.map(\.id))
        knownIDs = Set(ids)
        let current = Set(ids)
        sizes = sizes.filter { current.contains($0.key) }
        unmeasured = current
        items = discovery.items
        blocked = discovery.blocked
        switch listing {
        case .needsFullDiskAccess: trash = .needsFullDiskAccess
        case .contents(let children): trash = .contents(count: children.count, bytes: children.isEmpty ? 0 : nil)
        }
        hasListed = true
    }

    private func record(_ size: Int64, for id: String, generation: Int) {
        guard generation == self.generation else { return }
        sizes[id] = size
        unmeasured.remove(id)
    }
}

/// Sums Trash item sizes reported from concurrent measuring.
private actor TrashTotal {
    private(set) var bytes: Int64 = 0

    func add(_ size: Int64) {
        bytes += size
    }
}
