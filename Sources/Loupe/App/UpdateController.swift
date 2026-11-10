import AppKit
import Sparkle

/// Owns Sparkle's updater. Updates come from SUFeedURL (loupe.pics/appcast.xml)
/// and are verified against SUPublicEDKey before installing.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
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
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var updater: SPUUpdater { controller.updater }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        // Sparkle can't start its installer from a copy whose app was replaced or
        // removed on disk (see RunningCopy), so offer to reopen Loupe instead of
        // letting the update end in "An error occurred while launching the installer".
        let runningCopy = RunningCopy.state
        guard runningCopy == .intact else {
            explainStaleCopy(runningCopy)
            return
        }
        if pendingUpdateVersion != nil {
            // Brings the waiting update window forward.
            DockPresence.show()
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.checkForUpdates(sender)
    }

    private func explainStaleCopy(_ state: RunningCopy.State) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if state == .replaced {
            alert.messageText = "Loupe was replaced while it was running."
            alert.informativeText = "Another copy of Loupe was installed over this one. Reopen Loupe to use it, then check for updates again if you still need to."
            alert.addButton(withTitle: "Reopen Loupe")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                relaunch()
            }
        } else {
            alert.messageText = "Loupe was moved or deleted while it was running."
            alert.informativeText = "Quit Loupe and open it again from where it is now to check for updates."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Quits and opens the app now at this bundle's path.
    private func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // $0 is the bundle path, $1 our pid: wait for this process to exit, then reopen.
        waiter.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try waiter.run()
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        NSApp.terminate(nil)
        // Still here: quitting was cancelled (e.g. a recording in progress), so don't reopen later.
        waiter.terminate()
    }

    // MARK: - SPUUpdaterDelegate

    // Scheduled checks: skip them while this copy can't install anything. (Checks the
    // user starts go through checkForUpdates(_:), which explains why.)
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard RunningCopy.state == .intact else {
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationError.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "Loupe was replaced or moved while it was running. Quit and reopen Loupe to check for updates.",
            ])
        }
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
