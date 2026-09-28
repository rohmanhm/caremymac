import AppKit

/// Full Disk Access: macOS has no API to query it, so CareMyMac probes a file only it unlocks.
enum FullDiskAccess {
    /// Whether CareMyMac can read the user's privacy database, which macOS opens only with Full Disk Access.
    static var isGranted: Bool {
        let path = URL.homeDirectory.appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path(percentEncoded: false)
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    /// Privacy & Security › Full Disk Access in System Settings.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
