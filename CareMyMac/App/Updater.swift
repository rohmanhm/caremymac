import AppKit
import Observation
import Sparkle

/// Checks GitHub Releases for new versions and prompts to install them, through Sparkle.
///
/// The feed is the `appcast.xml` attached to the latest GitHub release (`SUFeedURL` in Info.plist), and every
/// update must be signed with the EdDSA key whose public half is `SUPublicEDKey`. Sparkle shows the prompt with
/// the release notes. Scheduled prompts wait until CareMyMac is in front, so `availableVersion` also surfaces the
/// update in the menu bar panel and Settings until the user acts on it.
@MainActor
@Observable
final class Updater: NSObject {
    private(set) var canCheckForUpdates = false
    private(set) var lastCheckDate: Date?
    /// Version of an update Sparkle found that the user hasn't installed, skipped or postponed yet, e.g. "0.2.0".
    private(set) var availableVersion: String?

    var automaticallyChecks = false {
        didSet {
            if controller.updater.automaticallyChecksForUpdates != automaticallyChecks {
                controller.updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }

    var automaticallyDownloads = false {
        didSet {
            if controller.updater.automaticallyDownloadsUpdates != automaticallyDownloads {
                controller.updater.automaticallyDownloadsUpdates = automaticallyDownloads
            }
        }
    }

    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func start() {
        #if DEBUG
        // Scheduled checks are off unless turned on in Settings; the delegate below refuses them anyway.
        if Self.debugFeedURL == nil { UserDefaults.standard.register(defaults: ["SUEnableAutomaticChecks": false]) }
        #endif
        controller.startUpdater()
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
        ]
        sync()
    }

    /// Checks now and shows the result. Brings an update that's already waiting back to the front.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    private func sync() {
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
        if automaticallyChecks != updater.automaticallyChecksForUpdates { automaticallyChecks = updater.automaticallyChecksForUpdates }
        if automaticallyDownloads != updater.automaticallyDownloadsUpdates { automaticallyDownloads = updater.automaticallyDownloadsUpdates }
    }

    #if DEBUG
    /// `-CareMyMacFeedURL <url>` points a Debug build at a test feed.
    private static var debugFeedURL: String? { UserDefaults.standard.string(forKey: "CareMyMacFeedURL") }
    #endif
}

extension Updater: SPUUpdaterDelegate {
    #if DEBUG
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.debugFeedURL
    }

    /// Debug builds never check in the background against the real feed: they'd offer to replace themselves with a release.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updatesInBackground, Self.debugFeedURL == nil {
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "Debug builds check for updates only when asked, or with -CareMyMacFeedURL.",
            ])
        }
    }
    #endif

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheckDate = updater.lastUpdateCheckDate
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
