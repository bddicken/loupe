import AppKit

/// Entry point for all capture actions and the after-capture pipeline.
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private var session: SelectionSession?
    private var isSnapshotting = false

    private init() {}

    func captureArea(mode: SelectionSession.Mode) {
        guard session == nil, !isSnapshotting else { return }
        isSnapshotting = true
        Task {
            defer { isSnapshotting = false }
            do {
                let windows = ScreenCapturer.visibleWindows()
                let snapshots = try await ScreenCapturer.snapshotAllDisplays(
                    excludingWindowNumbers: QuickAccessManager.shared.windowNumbers
                )
                guard !snapshots.isEmpty else { return }
                let session = SelectionSession(snapshots: snapshots, windows: windows, mode: mode) { [weak self] result in
                    self?.session = nil
                    switch result {
                    case let .image(image, scale): self?.didCapture(image, scale: scale)
                    case let .window(id): self?.captureWindow(id)
                    case nil: break
                    }
                }
                self.session = session
                session.begin()
            } catch {
                showCaptureError(error)
            }
        }
    }

    func captureFullscreen() {
        guard session == nil, !isSnapshotting, let screen = NSScreen.underMouse else { return }
        isSnapshotting = true
        Task {
            defer { isSnapshotting = false }
            do {
                let snapshots = try await ScreenCapturer.snapshot(
                    screens: [screen],
                    excludingWindowNumbers: QuickAccessManager.shared.windowNumbers
                )
                if let snapshot = snapshots.first {
                    didCapture(snapshot.image, scale: snapshot.scale)
                }
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func captureWindow(_ id: CGWindowID) {
        Task {
            do {
                if let (image, scale) = try await ScreenCapturer.captureWindow(id: id) {
                    didCapture(image, scale: scale)
                }
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func didCapture(_ image: CGImage, scale: CGFloat) {
        CaptureSound.play()
        let screenshot = Screenshot(image: image, scale: scale)

        if Preferences.autoSave {
            let url = ImageExport.newFileURL(for: screenshot.date)
            do {
                try ImageExport.write(image, scale: scale, to: url)
                screenshot.fileURL = url
            } catch {
                NSLog("Loupe: failed to save screenshot: \(error)")
            }
        }
        if Preferences.copyToClipboard {
            ImageExport.copyToPasteboard(image, scale: scale)
        }
        if Preferences.showQuickAccess {
            QuickAccessManager.shared.show(screenshot)
        }
    }

    private func showCaptureError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if CGPreflightScreenCaptureAccess() {
            alert.messageText = "Couldn’t take screenshot"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        alert.messageText = "Loupe needs Screen Recording permission"
        alert.informativeText = "Enable Loupe in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. You may need to relaunch Loupe."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
