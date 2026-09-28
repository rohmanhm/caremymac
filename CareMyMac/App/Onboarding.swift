import Foundation
import Observation

/// Whether the welcome sheet is over the main window.
///
/// `SettingsKey.onboardingCompleted` is absent until the sheet first appears, false while it's pending
/// (quitting before Get Started shows it again), and true once it's dismissed. A history store that exists
/// while the key is absent means CareMyMac ran before onboarding did, so that person never sees it.
@MainActor
@Observable
final class Onboarding {
    var isPresented: Bool {
        didSet {
            if oldValue, !isPresented { UserDefaults.standard.set(true, forKey: SettingsKey.onboardingCompleted) }
        }
    }

    /// `storeExists` must be read before the history store is opened, which creates it.
    init(storeExists: Bool) {
        isPresented = false
        let defaults = UserDefaults.standard
        #if DEBUG
        // `-CareMyMacShowOnboarding YES` shows it regardless; snapshot runs never show it otherwise.
        if defaults.bool(forKey: "CareMyMacShowOnboarding") {
            isPresented = true
            return
        }
        if defaults.string(forKey: "CareMyMacSnapshotDir") != nil { return }
        #endif
        switch defaults.object(forKey: SettingsKey.onboardingCompleted) as? Bool {
        case true?:
            break
        case false?:
            isPresented = true
        case nil where storeExists:
            defaults.set(true, forKey: SettingsKey.onboardingCompleted)
        case nil:
            defaults.set(false, forKey: SettingsKey.onboardingCompleted)
            isPresented = true
        }
    }
}
