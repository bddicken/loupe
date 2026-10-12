import AppKit

/// A remembered selection: which display, and where on it (screen-local points, y-up).
struct CaptureArea: Codable {
    let displayID: CGDirectDisplayID
    let rect: CGRect

    @MainActor
    var screen: NSScreen? { NSScreen.screens.first { $0.displayID == displayID } }
}

/// Entry point for all capture actions and the after-capture pipeline.
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private var session: SelectionSession?
    private var countdown: CountdownController?
    private var isBusy = false
    private let lastAreaKey = "lastCaptureArea"

    private init() {}

    private var lastArea: CaptureArea? {
        get {
            guard let data = UserDefaults.standard.data(forKey: lastAreaKey) else { return nil }
            return try? JSONDecoder().decode(CaptureArea.self, from: data)
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: lastAreaKey)
        }
    }

    private var canStart: Bool { session == nil && countdown == nil && !isBusy }

    /// Without Screen Recording permission, macOS still "captures" but returns only
    /// the wallpaper (or black video), so check first and explain instead.
    private func hasScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess() // Adds Loupe to the list in System Settings.
        showCaptureError(CocoaError(.userCancelled))
        return false
    }

    // MARK: - Actions

    func captureArea(mode: SelectionSession.Mode) {
        runSelection(mode: mode) { [weak self] result in
            switch result {
            case let .image(image, scale, area):
                self?.lastArea = area
                self?.didCapture(image, scale: scale)
            case let .window(id):
                self?.captureWindow(id)
            case .area:
                break
            }
        }
    }

    /// Picks an area, window or display to record (see ScreenRecordingController).
    func selectRecordingArea(completion: @escaping (CaptureArea) -> Void) {
        runSelection(mode: .record) { result in
            if case let .area(area) = result { completion(area) }
        }
    }

    func captureFullscreen() {
        guard canStart, let screen = NSScreen.underMouse else { return }
        captureFresh(screen: screen, rect: nil)
    }

    /// Re-captures the last selected area with fresh pixels.
    func capturePreviousArea() {
        guard canStart else { return }
        guard let area = lastArea, let screen = area.screen else {
            // Nothing remembered yet (or that display is gone): pick an area instead.
            captureArea(mode: .quick)
            return
        }
        captureFresh(screen: screen, rect: area.rect)
    }

    /// Select an area (or click a window), then count down and capture live
    /// pixels — handy for menus and hover states.
    func captureAreaWithTimer() {
        runSelection(mode: .quick) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .image(_, _, area):
                self.lastArea = area
                guard let screen = area.screen else { return }
                self.startCountdown(screen: screen, highlight: area.rect) {
                    self.captureFresh(screen: screen, rect: area.rect)
                }
            case let .window(id):
                guard let screen = NSScreen.underMouse else { return }
                self.startCountdown(screen: screen, highlight: nil) {
                    self.captureWindow(id)
                }
            case .area:
                break
            }
        }
    }

    func captureFullscreenWithTimer() {
        guard canStart, let screen = NSScreen.underMouse else { return }
        startCountdown(screen: screen, highlight: nil) { [weak self] in
            self?.captureFresh(screen: screen, rect: nil)
        }
    }

    // MARK: - Steps

    private func runSelection(mode: SelectionSession.Mode, completion: @escaping (SelectionSession.Result) -> Void) {
        guard canStart, hasScreenAccess() else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let windows = ScreenCapturer.visibleWindows()
                let snapshots = try await ScreenCapturer.snapshotAllDisplays(
                    excludingWindowNumbers: QuickAccessManager.shared.windowNumbers
                )
                guard !snapshots.isEmpty else { return }
                let session = SelectionSession(snapshots: snapshots, windows: windows, mode: mode) { [weak self] result in
                    self?.session = nil
                    if let result { completion(result) }
                }
                self.session = session
                session.begin()
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func startCountdown(screen: NSScreen, highlight: CGRect?, then action: @escaping () -> Void) {
        let countdown = CountdownController(screen: screen, highlight: highlight, seconds: Preferences.timerSeconds)
        self.countdown = countdown
        countdown.start { [weak self] finished in
            self?.countdown = nil
            if finished { action() }
        }
    }

    /// Takes a new snapshot of `screen`, optionally cropped to `rect` (screen-local points).
    private func captureFresh(screen: NSScreen, rect: CGRect?) {
        guard hasScreenAccess() else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let snapshots = try await ScreenCapturer.snapshot(
                    screens: [screen],
                    excludingWindowNumbers: QuickAccessManager.shared.windowNumbers.union(PinManager.shared.windowNumbers)
                )
                guard let snapshot = snapshots.first else { return }
                if let rect {
                    if let image = snapshot.crop(rect) {
                        didCapture(image, scale: snapshot.scale)
                    }
                } else {
                    didCapture(snapshot.image, scale: snapshot.scale)
                }
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func captureWindow(_ id: CGWindowID) {
        isBusy = true
        Task {
            defer { isBusy = false }
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

        var saveError: Error?
        if Preferences.autoSave {
            let url = ImageExport.newFileURL(for: screenshot.date)
            do {
                try ImageExport.write(image, scale: scale, to: url)
                screenshot.fileURL = url
            } catch {
                NSLog("Loupe: failed to save screenshot: \(error)")
                saveError = error
            }
        }
        HistoryStore.shared.add(screenshot)
        if Preferences.copyToClipboard {
            ImageExport.copyToPasteboard(image, scale: scale)
        }
        if Preferences.showQuickAccess {
            QuickAccessManager.shared.show(screenshot)
        }
        // Still in Capture History (and the thumbnail), but say so rather than pretend it was saved.
        if let saveError {
            showCaptureError(saveError, title: "Couldn’t save the screenshot to “\(Preferences.saveDirectory.lastPathComponent)”")
        }
    }

    func showCaptureError(_ error: Error, title: String = "Couldn’t take screenshot") {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if CGPreflightScreenCaptureAccess() {
            alert.messageText = title
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        alert.messageText = "Loupe needs Screen Recording permission"
        alert.informativeText = "Enable Loupe in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Loupe.\n\nIf Loupe is already switched on there, select it, click − to remove it, and enable it again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
