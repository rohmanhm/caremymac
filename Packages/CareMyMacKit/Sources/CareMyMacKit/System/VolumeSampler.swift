import Foundation

/// Lists user-visible mounted volumes with capacity figures.
public final class VolumeSampler {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeLocalizedNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsInternalKey,
        .volumeIsRemovableKey,
        .volumeLocalizedFormatDescriptionKey,
    ]

    public init() {}

    public func sample() -> [VolumeStats] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys, options: [.skipHiddenVolumes]) ?? []
        var volumes: [VolumeStats] = []
        for url in urls {
            let path = url.path(percentEncoded: false)
            let mountPath = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            guard !Self.isSystemMount(mountPath),
                  let values = try? url.resourceValues(forKeys: Set(Self.keys)),
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            let available = UInt64(max(values.volumeAvailableCapacity ?? 0, 0))
            let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) } ?? available
            volumes.append(VolumeStats(
                id: mountPath,
                name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
                totalBytes: UInt64(total),
                availableBytes: available,
                availableForImportantUsage: important,
                isInternal: values.volumeIsInternal ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isRoot: mountPath == "/",
                format: values.volumeLocalizedFormatDescription
            ))
        }
        return volumes.sorted { lhs, rhs in
            lhs.isRoot != rhs.isRoot ? lhs.isRoot : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// APFS system/data/VM mounts and Time Machine snapshot mounts duplicate the root volume.
    static func isSystemMount(_ path: String) -> Bool {
        path.hasPrefix("/System/Volumes/")
            || path.hasPrefix("/private/var/vm")
            || path.contains("com.apple.TimeMachine")
            || path.hasPrefix("/Volumes/.timemachine")
    }
}
