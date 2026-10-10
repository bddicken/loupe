import AppKit
import Sparkle

/// Owns Sparkle's updater. Updates come from SUFeedURL (loupe.pics/appcast.xml)
/// and are verified against SUPublicEDKey before installing.
@MainActor
final class UpdateController: NSObject, SPUStandardUserDriverDelegate {
    static let shared = UpdateController()

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var updater: SPUUpdater { controller.updater }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    // MARK: - SPUStandardUserDriverDelegate

    // Loupe lives in the menu bar, so scheduled update alerts are shown
    // "gently": we bring the app forward only while an update window is up.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            if !EditorWindowController.hasOpenEditors {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
