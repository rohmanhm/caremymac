import Foundation

/// The user's Trash (`~/.Trash`). Emptying it is the Cleanup page's one permanent deletion.
public enum CleanupTrash {
    public enum Listing: Sendable, Equatable {
        /// Top-level items in the Trash, hidden ones included; empty when the Trash is empty or missing.
        case contents([URL])
        /// macOS refused to list `~/.Trash`; CareMyMac needs Full Disk Access.
        case needsFullDiskAccess
    }

    public static func url(home: URL) -> URL {
        home.appending(path: ".Trash", directoryHint: .isDirectory)
    }

    public static func list(home: URL) -> Listing {
        do {
            let children = try FileManager.default.contentsOfDirectory(at: url(home: home), includingPropertiesForKeys: nil, options: [])
            return .contents(children.filter { $0.lastPathComponent != ".DS_Store" })
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .contents([])
        } catch let error as CocoaError where error.code == .fileReadNoPermission
            || CleanupScanner.isPermission((error as NSError).userInfo[NSUnderlyingErrorKey] as? Error) {
            return .needsFullDiskAccess
        } catch {
            return CleanupScanner.isPermission(error) ? .needsFullDiskAccess : .contents([])
        }
    }

    /// Permanently removes everything in the Trash with `FileManager.removeItem`, which deletes symlinks, not their targets.
    /// Returns the items that couldn't be removed.
    public static func empty(home: URL) -> [CareFailure] {
        switch list(home: home) {
        case .needsFullDiskAccess:
            return [CareFailure(path: url(home: home).path, message: "CareMyMac needs Full Disk Access to empty the Trash.")]
        case .contents(let children):
            return children.compactMap { child in
                do {
                    try FileManager.default.removeItem(at: child)
                    return nil
                } catch CocoaError.fileNoSuchFile {
                    return nil
                } catch {
                    return CareFailure(path: child.path, message: error.localizedDescription)
                }
            }
        }
    }
}
