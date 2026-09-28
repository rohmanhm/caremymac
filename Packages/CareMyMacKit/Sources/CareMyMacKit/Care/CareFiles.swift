import Foundation

/// An item that could not be moved to the Trash or removed, with the reason.
public struct CareFailure: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// Sizes and removal shared by Cleanup and Uninstaller. Removal goes to the Trash, so everything can be put back.
public enum CareFiles {
    private static let sizeKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]

    /// Allocated size of a file, or of everything under a folder. Never follows symlinks; unreadable items count as 0.
    /// Hard-linked files count once per link. Throws only `CancellationError`.
    public static func allocatedSize(of url: URL) throws -> Int64 {
        guard let values = try? url.resourceValues(forKeys: Set(sizeKeys)) else { return 0 }
        guard values.isDirectory == true else { return size(values) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: sizeKeys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        var visited = 0
        for case let item as URL in enumerator {
            visited += 1
            if visited & 1023 == 0 { try Task.checkCancellation() }
            guard let values = try? item.resourceValues(forKeys: Set(sizeKeys)), values.isDirectory != true else { continue }
            total += size(values)
        }
        try Task.checkCancellation()
        return total
    }

    /// Moves each item to the Trash. Returns the ones that failed; items already gone count as moved.
    public static func moveToTrash(_ urls: [URL]) -> [CareFailure] {
        urls.compactMap { url in
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return nil
            } catch CocoaError.fileNoSuchFile {
                return nil
            } catch {
                return CareFailure(path: url.path, message: error.localizedDescription)
            }
        }
    }

    private static func size(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
