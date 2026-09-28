import AppKit

/// Feeds `AppGrouper` with live facts from NSWorkspace and bundle Info.plists.
///
/// NSRunningApplication is thread safe; its time-varying state only changes when the main
/// run loop spins, so reading it from a background actor is safe.
public final class LiveAppGrouping {
    private let metadataCache = BundleMetadataCache()
    private let grouper: AppGrouper

    public init() {
        let cache = metadataCache
        grouper = AppGrouper(bundleMetadata: { cache.metadata(for: $0) })
    }

    public func group(_ processes: [ProcessStats]) -> [AppActivity] {
        grouper.group(processes: processes, runningApps: Self.runningApps())
    }

    public static func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated else { return nil }
            let policy: RunningAppInfo.ActivationPolicy = switch app.activationPolicy {
            case .regular: .regular
            case .accessory: .accessory
            default: .prohibited
            }
            let bundlePath = app.bundleURL.map { AppGrouper.normalized($0.standardizedFileURL.path) }
            let name = app.localizedName ?? bundlePath.map(AppGrouper.bundleFileName) ?? "pid \(app.processIdentifier)"
            return RunningAppInfo(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                                  bundlePath: bundlePath, name: name, activationPolicy: policy)
        }
    }
}

/// Bundle display names are read from disk once per bundle path.
private final class BundleMetadataCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: BundleMetadata?] = [:]

    func metadata(for path: String) -> BundleMetadata? {
        if let hit = lock.withLock({ cache[path] }) { return hit }
        let metadata = Bundle(path: path).map { bundle in
            let info = bundle.localizedInfoDictionary ?? [:]
            let base = bundle.infoDictionary ?? [:]
            let name = (info["CFBundleDisplayName"] ?? base["CFBundleDisplayName"] ?? info["CFBundleName"] ?? base["CFBundleName"]) as? String
            return BundleMetadata(name: name?.nonEmptyName ?? AppGrouper.bundleFileName(path),
                                  bundleIdentifier: bundle.bundleIdentifier)
        }
        lock.withLock { cache[path] = .some(metadata) }
        return metadata
    }
}

private extension String {
    var nonEmptyName: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
