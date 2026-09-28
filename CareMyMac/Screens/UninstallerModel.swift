import AppKit
import CareMyMacKit
import Observation

/// Installed apps, their sizes and the selected app’s leftovers for the Uninstaller page. Owned by the page:
/// its work runs in the page’s tasks, so leaving the page cancels scans.
@Observable
@MainActor
final class UninstallerModel {
    enum Sort: String, CaseIterable, Identifiable {
        case size, name, lastOpened
        var id: Self { self }
        var title: String {
            switch self {
            case .size: "Size"
            case .name: "Name"
            case .lastOpened: "Last Opened"
            }
        }
    }

    nonisolated struct LeftoverRow: Identifiable, Hashable, Sendable {
        let leftover: UninstallLeftover
        let bytes: Int64
        /// The folder exists but macOS wouldn’t let CareMyMac look inside, so `bytes` is incomplete.
        let isUnreadable: Bool
        var id: String { leftover.id }
    }

    struct Leftovers {
        let appID: String
        let rows: [LeftoverRow]
        let deniedFolders: [String]
    }

    /// What the last removal did, shown until the next removal or a different app is picked.
    struct Removal {
        let appID: String
        let appName: String
        let removedApp: Bool
        let movedCount: Int
        let movedBytes: Int64
        let failures: [CareFailure]
        /// The bundle itself couldn’t be moved, so its leftovers were left alone.
        let bundleFailed: Bool
        /// The bundle failed for lack of permission (an installer put it there as root), so an administrator move may work.
        let needsAdministrator: Bool
    }

    private(set) var apps: [InstalledApp] = []
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var sizes: [String: Int64] = [:]
    private(set) var lastOpened: [String: Date] = [:]
    private(set) var leftovers: Leftovers?
    private(set) var removal: Removal?
    private(set) var isRemoving = false
    /// Leftover paths the user unticked. Everything else is selected.
    var deselected: Set<String> = []
    var selectedID: String?

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var leftoverGeneration = 0

    var selectedApp: InstalledApp? {
        selectedID.flatMap { id in apps.first { $0.id == id } }
    }

    func visibleApps(sort: Sort, query: String) -> [InstalledApp] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
        }
        switch sort {
        case .name:
            return matching
        case .size:
            return matching.sorted { (sizes[$0.id] ?? -1) > (sizes[$1.id] ?? -1) }
        case .lastOpened:
            // Longest unused first; apps macOS never recorded go last.
            return matching.sorted { (lastOpened[$0.id] ?? .distantFuture) < (lastOpened[$1.id] ?? .distantFuture) }
        }
    }

    /// Other listed copies of the app (same bundle ID elsewhere) share its leftovers.
    func hasOtherCopy(of app: InstalledApp) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return apps.contains { $0.id != app.id && $0.bundleIdentifier?.caseInsensitiveCompare(id) == .orderedSame }
    }

    // MARK: Loading

    /// Lists the apps, then measures each bundle in the background. Runs for the life of the page task.
    func load() async {
        await refreshList()
        for app in apps where sizes[app.id] == nil {
            guard let bytes = try? await Self.size(app.url) else { return }
            sizes[app.id] = bytes
        }
    }

    private func refreshList() async {
        let roots = UninstallAppFinder.standardRoots(home: home)
        let excluded: Set<String> = Bundle.main.bundleIdentifier.map { [$0] } ?? []
        do {
            let listed = try await Self.list(roots: roots, excluding: excluded)
            apps = listed.map(\.app)
            lastOpened = Dictionary(uniqueKeysWithValues: listed.compactMap { item in item.lastOpened.map { (item.app.id, $0) } })
            let ids = Set(apps.map(\.id))
            sizes = sizes.filter { ids.contains($0.key) }
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Finds and measures the selected app’s leftovers, and measures its bundle if the background pass hasn’t yet.
    func loadLeftovers() async {
        leftoverGeneration += 1
        let generation = leftoverGeneration
        guard let app = selectedApp else {
            leftovers = nil
            return
        }
        if leftovers?.appID != app.id {
            leftovers = nil
            deselected = []
        }
        if removal?.appID != app.id { removal = nil }
        let home = home
        do {
            if sizes[app.id] == nil {
                let bytes = try await Self.size(app.url)
                sizes[app.id] = bytes
            }
            let scan = try await Self.leftovers(for: app, home: home)
            guard generation == leftoverGeneration else { return }
            let fresh = leftovers?.appID != app.id
            leftovers = Leftovers(appID: app.id, rows: scan.rows, deniedFolders: scan.denied)
            // Another copy of the app still uses these files, so nothing is ticked until the user chooses.
            if fresh, hasOtherCopy(of: app) { deselected = Set(scan.rows.map(\.id)) }
        } catch {
            return
        }
    }

    // MARK: Removal

    func selectedLeftovers(for app: InstalledApp) -> [LeftoverRow] {
        guard let leftovers, leftovers.appID == app.id else { return [] }
        return leftovers.rows.filter { !deselected.contains($0.id) }
    }

    /// Moves the bundle (when `includingApp`) and the ticked leftovers to the Trash, then rescans.
    /// When the bundle can’t be moved, its leftovers and their selection stay put so the app keeps working.
    func remove(_ app: InstalledApp, includingApp: Bool) async {
        guard !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        let rows = selectedLeftovers(for: app)
        if includingApp {
            switch await Self.trashBundle(app.url) {
            case .moved:
                break
            case .needsAdministrator(let failure):
                await bundleStayed(app, failure: failure, needsAdministrator: true)
                return
            case .failed(let failure):
                await bundleStayed(app, failure: failure, needsAdministrator: false)
                return
            }
        }
        await trashLeftovers(rows, of: app, removedApp: includingApp)
    }

    /// Moves a root-owned bundle into the Trash after macOS asks for an administrator password, then the ticked leftovers.
    /// Cancelling the password dialog leaves everything as it was.
    func removeAsAdministrator(_ app: InstalledApp) async {
        guard !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        let rows = selectedLeftovers(for: app)
        switch await UninstallTrash.moveToTrashAsAdministrator(app.url, home: home) {
        case .cancelled:
            return
        case .failed(let failure):
            await bundleStayed(app, failure: failure, needsAdministrator: true)
        case .moved:
            await trashLeftovers(rows, of: app, removedApp: true)
        }
    }

    private func bundleStayed(_ app: InstalledApp, failure: CareFailure, needsAdministrator: Bool) async {
        removal = Removal(
            appID: app.id,
            appName: app.name,
            removedApp: false,
            movedCount: 0,
            movedBytes: 0,
            failures: [failure],
            bundleFailed: true,
            needsAdministrator: needsAdministrator
        )
        await refreshAfterRemoval()
    }

    private func trashLeftovers(_ rows: [LeftoverRow], of app: InstalledApp, removedApp: Bool) async {
        let failures = await Self.trash(rows.map(\.leftover.url))
        let failed = Set(failures.map(\.path))
        let moved = rows.filter { !failed.contains($0.leftover.url.path) }
        removal = Removal(
            appID: app.id,
            appName: app.name,
            removedApp: removedApp,
            movedCount: moved.count + (removedApp ? 1 : 0),
            movedBytes: moved.reduce(0) { $0 + $1.bytes } + (removedApp ? sizes[app.id] ?? 0 : 0),
            failures: failures,
            bundleFailed: false,
            needsAdministrator: false
        )
        leftovers = nil
        deselected = []
        await refreshAfterRemoval()
    }

    private func refreshAfterRemoval() async {
        await refreshList()
        if selectedApp == nil {
            selectedID = nil
            leftovers = nil
        } else {
            await loadLeftovers()
        }
    }

    func dismissRemoval() {
        removal = nil
    }

    /// Asks every running copy of the app to quit, like choosing Quit in its menu. Never forces.
    func quit(_ app: InstalledApp) {
        for running in Self.running(app) { running.terminate() }
    }

    static func running(_ app: InstalledApp) -> [NSRunningApplication] {
        guard let id = app.bundleIdentifier else {
            return NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.path == app.url.standardizedFileURL.path }
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated }
    }

    // MARK: Background work

    nonisolated private struct Listed: Sendable {
        let app: InstalledApp
        let lastOpened: Date?
    }

    nonisolated private struct LeftoverResult: Sendable {
        let rows: [LeftoverRow]
        let denied: [String]
    }

    @concurrent
    private static func list(roots: [URL], excluding: Set<String>) async throws -> [Listed] {
        try UninstallAppFinder.apps(in: roots, excluding: excluding).map { app in
            try Task.checkCancellation()
            return Listed(app: app, lastOpened: UninstallAppFinder.lastUsedDate(of: app.url))
        }
    }

    @concurrent
    private static func size(_ url: URL) async throws -> Int64 {
        try CareFiles.allocatedSize(of: url)
    }

    @concurrent
    private static func leftovers(for app: InstalledApp, home: URL) async throws -> LeftoverResult {
        let scan = try UninstallLeftoverFinder.leftovers(for: app, home: home)
        let rows = try scan.leftovers.map { leftover in
            LeftoverRow(
                leftover: leftover,
                bytes: try CareFiles.allocatedSize(of: leftover.url),
                isUnreadable: UninstallLeftoverFinder.isUnreadable(leftover.url)
            )
        }
        return LeftoverResult(rows: rows, denied: scan.deniedFolders)
    }

    @concurrent
    private static func trash(_ urls: [URL]) async -> [CareFailure] {
        CareFiles.moveToTrash(urls)
    }

    @concurrent
    private static func trashBundle(_ url: URL) async -> UninstallTrash.BundleResult {
        UninstallTrash.moveToTrash(url)
    }
}
