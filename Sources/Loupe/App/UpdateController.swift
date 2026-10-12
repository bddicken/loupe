import AppKit
import Sparkle

/// Owns Sparkle's updater. Updates come from SUFeedURL (loupe.pics/appcast.xml)
/// and are verified against SUPublicEDKey before installing.
@MainActor
final class UpdateController: NSObject, SPUStandardUserDriverDelegate {
    static let shared = UpdateController()
    static let pendingUpdateDidChange = Notification.Name("LoupePendingUpdateDidChange")

    /// A scheduled check found this version while the user was busy elsewhere; it's
    /// offered from the menu bar instead of interrupting them.
    private(set) var pendingUpdateVersion: String? {
        didSet { NotificationCenter.default.post(name: Self.pendingUpdateDidChange, object: nil) }
    }

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
        if pendingUpdateVersion != nil {
            // Brings the waiting update window forward.
            DockPresence.show()
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.checkForUpdates(sender)
    }

    // MARK: - SPUStandardUserDriverDelegate

    // Loupe lives in the menu bar, so scheduled updates are shown "gently": the
    // update window only appears on its own when Sparkle can give it focus without
    // interrupting (e.g. just after launch); otherwise the menu bar menu offers it.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            guard handleShowingUpdate else {
                pendingUpdateVersion = version
                return
            }
            DockPresence.show()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pendingUpdateVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            pendingUpdateVersion = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DockPresence.refresh() }
            }
        }
    }
}
