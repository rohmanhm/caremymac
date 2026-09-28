import Foundation

/// Persists the latest `StorageIndexResult` as JSON (the app uses
/// `~/Library/Application Support/CareMyMac/storage-index.json`).
public struct StorageIndexStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The saved result, or nil when nothing has been saved yet.
    public func load() throws -> StorageIndexResult? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(StorageIndexResult.self, from: data)
    }

    public func save(_ result: StorageIndexResult) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(result).write(to: url, options: .atomic)
    }
}
