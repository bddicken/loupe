import AVFoundation
import AppKit
import ScreenCaptureKit

/// A finished screen recording, shown in the quick access stack.
final class Recording {
    var fileURL: URL
    let date: Date
    let duration: Double
    let thumbnail: CGImage?
    /// Pixels per point of the display it came from.
    let scale: CGFloat
    /// True until the file is saved somewhere the user chose (or auto-saved).
    var isTemporary: Bool

    var isGIF: Bool { fileURL.pathExtension.lowercased() == "gif" }

    init(fileURL: URL, date: Date, duration: Double, thumbnail: CGImage?, scale: CGFloat, isTemporary: Bool) {
        self.fileURL = fileURL
        self.date = date
        self.duration = duration
        self.thumbnail = thumbnail
        self.scale = scale
        self.isTemporary = isTemporary
    }
}

/// Select an area (or window, or the full screen), count down, then record it
/// to MP4 or GIF with a control bar for stop / restart / discard.
@MainActor
final class ScreenRecordingController {
    static let shared = ScreenRecordingController()
    static let stateDidChange = Notification.Name("LoupeRecordingStateDidChange")

    enum State: Equatable {
        case idle, countingDown, starting, recording, finishing
    }

    private(set) var state: State = .idle {
        didSet { NotificationCenter.default.post(name: Self.stateDidChange, object: nil) }
    }
    /// Seconds recorded so far.
    var elapsed: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// Recording, or about to start / finishing up: hot keys and the menu bar stop it.
    var isActive: Bool { state != .idle }

    /// The outline and control bar, kept out of screenshots taken while recording.
    var chromeWindowNumbers: Set<Int> { overlay?.excludedWindowNumbers ?? [] }
    /// Other windows left out of the recording for now (e.g. a screenshot's selection overlay).
    private var temporarilyExcluded: Set<Int> = []
    private var filterGeneration = 0
    /// The recorder being started, and whether its stream already failed before it got going.
    private weak var startingRecorder: ScreenRecorder?
    private var failedWhileStarting = false

    private var countdown: CountdownController?
    private var overlay: RecordingOverlay?
    private var recorder: ScreenRecorder?
    private var area: CaptureArea?
    private var date = Date()
    private var startedAt: Date?
    private var ticker: Timer?

    private init() {}

    // MARK: - Actions

    /// The Record Screen shortcut: starts a new recording, or stops the current one.
    func toggle() {
        switch state {
        case .idle: begin()
        case .recording: stop()
        case .countingDown, .starting, .finishing: break
        }
    }

    func begin() {
        guard state == .idle else { return }
        CaptureController.shared.selectRecordingArea { [weak self] area in
            guard let self, self.state == .idle, let screen = area.screen else { return }
            self.area = area
            Task { await self.prepare(screen: screen, area: area) }
        }
    }

    func stop() {
        guard state == .recording, let recorder else { return }
        state = .finishing
        startedAt = nil
        stopTicker()
        overlay?.close()
        overlay = nil
        self.recorder = nil
        Task {
            do {
                let duration = try await recorder.stop()
                await finish(movie: recorder.outputURL, duration: duration)
            } catch {
                // The movie couldn't be finalized (e.g. the disk filled up), but it's written
                // in fragments: keep whatever plays.
                if let duration = await RecordingExport.playableDuration(of: recorder.outputURL) {
                    await finish(movie: recorder.outputURL, duration: duration)
                } else {
                    try? FileManager.default.removeItem(at: recorder.outputURL)
                }
                CaptureController.shared.showCaptureError(error, title: "Couldn’t save the recording")
            }
            reset()
        }
    }

    /// Throws away what's been recorded and starts again on the same area.
    func restart() {
        guard state == .recording, let recorder, let area, let screen = area.screen, let overlay else { return }
        state = .starting
        self.recorder = nil
        startedAt = nil
        date = Date()
        stopTicker()
        Task {
            await recorder.cancel()
            do {
                try await startRecorder(screen: screen, area: area, overlay: overlay)
            } catch {
                fail(error)
            }
        }
    }

    func cancel() {
        guard state == .recording, let recorder else { return }
        state = .finishing
        overlay?.close()
        overlay = nil
        self.recorder = nil
        stopTicker()
        Task {
            await recorder.cancel()
            reset()
        }
    }

    /// `Loupe --debug-record <seconds>`: records the main display, skipping the
    /// selection overlay and countdown (handy for development).
    func debugRecord(seconds: Double) {
        guard state == .idle, let screen = NSScreen.main, let displayID = screen.displayID else { return }
        let area = CaptureArea(displayID: displayID, rect: CGRect(origin: .zero, size: screen.frame.size))
        self.area = area
        Task {
            await start(screen: screen, area: area)
            try? await Task.sleep(for: .seconds(seconds))
            stop()
        }
    }

    /// Asks before quitting mid-recording, which would lose it. False cancels the quit.
    func confirmQuit() -> Bool {
        switch state {
        case .idle, .countingDown:
            return true
        case .starting:
            // Not recording yet: don't leave a movie behind to recover on the next launch.
            if let startingRecorder { try? FileManager.default.removeItem(at: startingRecorder.outputURL) }
            return true
        case .recording:
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Loupe is recording."
            alert.informativeText = "Quitting now will throw the recording away. Stop it first to keep it."
            alert.addButton(withTitle: "Stop Recording")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit and Discard").hasDestructiveAction = true
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                stop()
                return false
            case .alertThirdButtonReturn:
                // Otherwise it would be recovered on the next launch.
                if let recorder { try? FileManager.default.removeItem(at: recorder.outputURL) }
                return true
            default:
                return false
            }
        case .finishing:
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Loupe is still saving a recording."
            alert.informativeText = "Wait a moment, then quit again. If you quit now, Loupe will recover what it can the next time it opens."
            alert.addButton(withTitle: "Wait")
            alert.addButton(withTitle: "Quit Anyway").hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn
        }
    }

    /// Leaves `windowNumbers` out of the recording (on top of the recording's own chrome)
    /// until called again; pass [] to show everything again.
    func excludeTemporarily(_ windowNumbers: Set<Int>) {
        guard state == .recording, let recorder, let area, temporarilyExcluded != windowNumbers else { return }
        temporarilyExcluded = windowNumbers
        filterGeneration += 1
        let generation = filterGeneration
        let excluded = chromeWindowNumbers.union(windowNumbers)
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  // A later call superseded this one, or the recording moved on.
                  generation == filterGeneration, recorder === self.recorder,
                  let filter = Self.makeFilter(content: content, displayID: area.displayID, excluding: excluded) else { return }
            try? await recorder.updateFilter(filter)
        }
    }

    private static func makeFilter(content: SCShareableContent, displayID: CGDirectDisplayID, excluding excluded: Set<Int>) -> SCContentFilter? {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        return SCContentFilter(display: display, excludingWindows: content.windows.filter { excluded.contains(Int($0.windowID)) })
    }

    // MARK: - Steps

    private func prepare(screen: NSScreen, area: CaptureArea) async {
        // Ask for the microphone before the countdown, so the prompt doesn't interrupt it.
        if Preferences.recordingFormat == .mp4, Preferences.recordMicrophone,
           AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard Preferences.recordingCountdown else {
            await start(screen: screen, area: area)
            return
        }
        state = .countingDown
        let isFullscreen = area.rect.size == screen.frame.size
        let countdown = CountdownController(screen: screen, highlight: isFullscreen ? nil : area.rect, seconds: 3)
        self.countdown = countdown
        countdown.start { [weak self] finished in
            guard let self else { return }
            self.countdown = nil
            guard finished else {
                self.reset()
                return
            }
            Task { await self.start(screen: screen, area: area) }
        }
    }

    private func start(screen: NSScreen, area: CaptureArea) async {
        state = .starting
        let overlay = RecordingOverlay(screen: screen, localArea: area.rect, actions: .init(
            stop: { [weak self] in self?.stop() },
            restart: { [weak self] in self?.restart() },
            cancel: { [weak self] in self?.cancel() }
        ))
        overlay.show(highlightClicks: Preferences.highlightClicks)
        self.overlay = overlay
        date = Date()
        do {
            try await startRecorder(screen: screen, area: area, overlay: overlay)
        } catch {
            fail(error)
        }
    }

    private func startRecorder(screen: NSScreen, area: CaptureArea, overlay: RecordingOverlay) async throws {
        let configuration = try await makeConfiguration(screen: screen, area: area, overlay: overlay)
        let url = RecordingExport.unfinishedDirectory.appendingPathComponent("Recording-\(UUID().uuidString).mov")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let recorder = try ScreenRecorder(configuration: configuration, outputURL: url)
        recorder.onStreamError = { [weak self, weak recorder] _ in
            // e.g. sharing was stopped from the system menu, or the file can't be
            // written (disk full): stop now rather than recording into the void.
            // Errors from a recorder that was already restarted or discarded don't count.
            guard let self, let recorder else { return }
            if self.recorder === recorder {
                self.stop()
            } else if self.startingRecorder === recorder {
                self.failedWhileStarting = true
            }
        }
        startingRecorder = recorder
        failedWhileStarting = false
        defer { startingRecorder = nil }
        try await recorder.start()
        self.recorder = recorder
        startedAt = Date()
        state = .recording
        startTicker()
        if failedWhileStarting { stop() }
    }

    private func makeConfiguration(screen: NSScreen, area: CaptureArea, overlay: RecordingOverlay) async throws -> RecordingConfiguration {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Leave out only the recording chrome (outline and control bar), so the rest of
        // Loupe (editor, pins, thumbnails, click ripples) shows up like any other app.
        guard let display = content.displays.first(where: { $0.displayID == area.displayID }),
              let filter = Self.makeFilter(content: content, displayID: area.displayID, excluding: overlay.excludedWindowNumbers) else {
            throw RecordingError.displayUnavailable
        }

        let rect = area.rect
        let scale = screen.backingScaleFactor
        // H.264 tops out around 4096 × 2304; scale larger areas down to fit.
        let fit = min(1, 4096 / (rect.width * scale), 2304 / (rect.height * scale))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale * fit / 2).rounded() * 2) }

        // GIFs have no sound, so don't record any.
        let wantsAudio = Preferences.recordingFormat == .mp4
        var microphone: AVCaptureDevice?
        if wantsAudio, Preferences.recordMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            microphone = AVCaptureDevice.default(for: .audio)
        }
        return RecordingConfiguration(
            display: display,
            filter: filter,
            sourceRect: CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height),
            pixelSize: CGSize(width: even(rect.width), height: even(rect.height)),
            framesPerSecond: Preferences.recordingFrameRate,
            showsCursor: Preferences.recordCursor,
            capturesSystemAudio: wantsAudio && Preferences.recordSystemAudio,
            microphone: microphone
        )
    }

    /// Converts the finished movie to MP4 (or GIF) in its place and shows it.
    /// If that fails, the recording is still shown from its temporary file rather than lost.
    private func finish(movie: URL, duration: Double) async {
        let format = Preferences.recordingFormat
        var destination = Preferences.autoSave
            ? RecordingExport.newFileURL(for: date, format: format)
            : FileManager.default.temporaryDirectory
                .appendingPathComponent("Loupe", isDirectory: true)
                .appendingPathComponent(RecordingExport.defaultFileName(for: date, format: format))
        var isTemporary = !Preferences.autoSave

        do {
            if Preferences.autoSave {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            } else {
                try? FileManager.default.removeItem(at: destination)
            }
            if format == .gif {
                try await GIFExporter.export(movie: movie, to: destination)
            } else {
                try await RecordingExport.convertToMP4(movie, to: destination)
            }
            try? FileManager.default.removeItem(at: movie)
        } catch {
            try? FileManager.default.removeItem(at: destination) // A partly written file.
            destination = movie
            isTemporary = true
            CaptureController.shared.showCaptureError(
                error,
                title: format == .gif ? "Couldn’t convert the recording to a GIF" : "Couldn’t save the recording"
            )
        }

        NSLog("Loupe: saved recording (%.1fs) to %@", duration, destination.path)
        CaptureSound.play()
        let recording = Recording(
            fileURL: destination,
            date: date,
            duration: duration,
            thumbnail: await RecordingExport.thumbnail(for: destination),
            scale: area?.screen?.backingScaleFactor ?? 2,
            isTemporary: isTemporary
        )
        if Preferences.copyToClipboard {
            RecordingExport.copyToPasteboard(recording.fileURL)
        }
        if Preferences.showQuickAccess {
            QuickAccessManager.shared.show(recording)
        } else if isTemporary {
            // Nowhere else to find it: reveal the temporary file.
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    private func fail(_ error: Error) {
        overlay?.close()
        overlay = nil
        recorder = nil
        stopTicker()
        reset()
        CaptureController.shared.showCaptureError(error, title: "Couldn’t start recording")
    }

    private func reset() {
        temporarilyExcluded = []
        countdown = nil
        area = nil
        startedAt = nil
        state = .idle
    }

    // MARK: - Clock

    private func startTicker() {
        refresh()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func refresh() {
        overlay?.update(elapsed: elapsed)
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }
}

enum RecordingFormat: String, CaseIterable, Identifiable {
    case mp4, gif

    var id: String { rawValue }
    var displayName: String { self == .mp4 ? "MP4 video" : "Animated GIF" }
    var fileExtension: String { rawValue }
}

enum RecordingExport {
    /// Where movies are written while recording. Not the temporary folder, which macOS
    /// clears, so a recording interrupted by a crash is still there on the next launch.
    static let unfinishedDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Loupe/Unfinished Recordings", isDirectory: true)
    }()

    /// Rewraps a recorded movie as an MP4 without re-encoding, laid out for streaming.
    static func convertToMP4(_ movie: URL, to destination: URL) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: movie), presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.shouldOptimizeForNetworkUse = true
        if #available(macOS 15, *) {
            try await session.export(to: destination, as: .mp4)
        } else {
            session.outputURL = destination
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else {
                throw session.error ?? CocoaError(.fileWriteUnknown)
            }
        }
    }

    /// The length of a movie that has at least one playable frame, or nil.
    static func playableDuration(of movie: URL) async -> Double? {
        let asset = AVURLAsset(url: movie)
        guard let (isPlayable, duration) = try? await asset.load(.isPlayable, .duration),
              isPlayable, duration.seconds > 0 else { return nil }
        return duration.seconds
    }

    static func defaultFileName(for date: Date, format: RecordingFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Loupe Recording \(formatter.string(from: date)).\(format.fileExtension)"
    }

    /// A non-colliding URL in the save directory.
    static func newFileURL(for date: Date, format: RecordingFormat) -> URL {
        let directory = Preferences.saveDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = defaultFileName(for: date, format: format)
        var url = directory.appendingPathComponent(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let stem = (base as NSString).deletingPathExtension
            url = directory.appendingPathComponent("\(stem) (\(counter)).\(format.fileExtension)")
            counter += 1
        }
        return url
    }

    static func thumbnail(for url: URL) async -> CGImage? {
        if url.pathExtension.lowercased() == "gif" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        return try? await generator.image(at: .zero).image
    }

    /// Copies the file itself, so it pastes into Finder, Slack, Mail, etc.
    @MainActor
    static func copyToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
}
