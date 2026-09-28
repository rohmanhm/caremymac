import Darwin
import Foundation

/// Moves an app bundle to the Trash. Bundles an installer put in place as root (pkg and App Store installs) refuse the
/// normal move; for those the user can approve an administrator `mv` into `~/.Trash`.
public enum UninstallTrash {
    /// Outcome of the normal, unprivileged move.
    public enum BundleResult: Sendable, Hashable {
        case moved
        /// macOS refused for lack of permission, so an administrator move may work.
        case needsAdministrator(CareFailure)
        case failed(CareFailure)
    }

    /// Outcome of the administrator move.
    public enum AdministratorResult: Sendable, Hashable {
        /// The bundle is now at this path in the Trash.
        case moved(URL)
        /// The user clicked Cancel in the password dialog.
        case cancelled
        case failed(CareFailure)
    }

    /// Moves the bundle to the Trash as the user. A bundle that is already gone counts as moved.
    public static func moveToTrash(_ bundle: URL) -> BundleResult {
        do {
            try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
            return .moved
        } catch CocoaError.fileNoSuchFile {
            return .moved
        } catch {
            let failure = CareFailure(path: bundle.path, message: error.localizedDescription)
            return UninstallLeftoverFinder.isPermissionDenied(error) ? .needsAdministrator(failure) : .failed(failure)
        }
    }

    /// Moves the bundle into `home/.Trash` with `/bin/mv` as root, after macOS asks for an administrator password.
    /// The destination is a name verified free beforehand, so `mv` never moves the bundle into an existing folder;
    /// `-n` refuses to replace anything that appears meanwhile. Succeeds only when the bundle left its place and arrived.
    public static func moveToTrashAsAdministrator(_ bundle: URL, home: URL) async -> AdministratorResult {
        let trash = home.appending(path: ".Trash", directoryHint: .isDirectory)
        func failure(_ message: String) -> AdministratorResult { .failed(CareFailure(path: bundle.path, message: message)) }
        guard isDirectory(trash) else { return failure("Your Trash folder (~/.Trash) is missing.") }
        guard let destination = trashDestination(for: bundle, in: trash, date: .now, isFree: isFree) else {
            return failure("CareMyMac couldn’t pick a free name for it in the Trash.")
        }
        let result: CommandResult
        do {
            result = try await OptimizeCommand.run(OptimizeCommand.osascript, administratorMoveArguments(from: bundle, to: destination))
        } catch {
            return failure(error.localizedDescription)
        }
        if OptimizeCommand.isUserCancel(result) { return .cancelled }
        guard result.succeeded else {
            let message = OptimizeCommand.scriptErrorMessage(result)
            return failure(message.isEmpty ? "The administrator move failed." : message)
        }
        guard isFree(bundle), exists(destination) else {
            return failure("It’s still in place after the administrator move.")
        }
        return .moved(destination)
    }

    /// `osascript` arguments that move `source` to `destination` as root.
    public static func administratorMoveArguments(from source: URL, to destination: URL) -> [String] {
        OptimizeCommand.administratorArguments([["/bin/mv", "-n", "--", source.path, destination.path]])
    }

    /// Where the bundle goes in `trash`, named like Finder does: `Name.app`, else `Name HH.mm.ss.app`,
    /// else `Name HH.mm.ss 2.app`, `… 3.app` and so on. Nil when no name `isFree` within 1,000 tries.
    public static func trashDestination(for bundle: URL, in trash: URL, date: Date, calendar: Calendar = .current, isFree: (URL) -> Bool) -> URL? {
        let base = bundle.deletingPathExtension().lastPathComponent
        let suffix = bundle.pathExtension.isEmpty ? "" : ".\(bundle.pathExtension)"
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        let stamp = [time.hour, time.minute, time.second].map { String(format: "%02d", $0 ?? 0) }.joined(separator: ".")
        let names = ["\(base)\(suffix)", "\(base) \(stamp)\(suffix)"] + (2..<1000).map { "\(base) \(stamp) \($0)\(suffix)" }
        return names.lazy
            .map { trash.appending(path: $0, directoryHint: .notDirectory) }
            .first(where: isFree)
    }

    // MARK: Private

    /// Nothing at the path, not even a dangling symlink. Unknown (e.g. permission denied) is not free.
    private static func isFree(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
