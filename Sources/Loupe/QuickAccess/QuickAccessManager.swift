import AppKit
import SwiftUI

/// Floating thumbnails stacked in the bottom-left corner after each capture.
@MainActor
final class QuickAccessManager {
    static let shared = QuickAccessManager()

    private var panels: [QuickAccessPanel] = []
    private let maxPanels = 6
    private let margin: CGFloat = 16
    private let spacing: CGFloat = 12

    private init() {}

    /// Used to keep the thumbnails out of later screenshots.
    var windowNumbers: Set<Int> { Set(panels.map(\.windowNumber)) }

    func show(_ screenshot: Screenshot) {
        let size = QuickAccessPanel.thumbnailSize(forPixels: NSSize(width: screenshot.image.width, height: screenshot.image.height))
        present(QuickAccessPanel(size: size) { dismiss in
            QuickAccessView(screenshot: screenshot, size: size, dismiss: dismiss)
        })
    }

    func show(_ recording: Recording) {
        let pixels = recording.thumbnail.map { NSSize(width: $0.width, height: $0.height) } ?? NSSize(width: 16, height: 10)
        let size = QuickAccessPanel.thumbnailSize(forPixels: pixels)
        let panel = QuickAccessPanel(size: size) { dismiss in
            RecordingQuickAccessView(recording: recording, size: size, dismiss: dismiss)
        }
        panel.holdsUnsavedWork = { recording.isTemporary }
        present(panel)
    }

    private func present(_ panel: QuickAccessPanel) {
        panel.onDismiss = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.dismiss(panel)
        }
        panels.insert(panel, at: 0)
        // Push out the oldest thumbnails, but never an unsaved recording: it's the only way back to it.
        while panels.count > maxPanels, let oldest = panels.lastIndex(where: { !$0.holdsUnsavedWork() }) {
            panels.remove(at: oldest).orderOut(nil)
        }

        layout(animated: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func dismiss(_ panel: QuickAccessPanel) {
        panels.removeAll { $0 === panel }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        layout(animated: true)
    }

    private func layout(animated: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var y = visible.minY + margin
        for panel in panels {
            let frame = NSRect(origin: NSPoint(x: visible.minX + margin, y: y), size: panel.frame.size)
            if animated, panel.isVisible {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
            y += frame.height + spacing
        }
    }
}

final class QuickAccessPanel: NSPanel {
    var onDismiss: (() -> Void)?
    /// True while closing this thumbnail would lose something (an unsaved recording).
    var holdsUnsavedWork: () -> Bool = { false }

    @MainActor
    init<Content: View>(size: NSSize, content: (_ dismiss: @escaping () -> Void) -> Content) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let dismiss: () -> Void = { [weak self] in self?.onDismiss?() }
        contentView = FirstMouseHostingView(rootView: content(dismiss))
    }

    override var canBecomeKey: Bool { true }

    static func thumbnailSize(forPixels pixel: NSSize) -> NSSize {
        let maxSize = NSSize(width: 220, height: 150)
        let minSize = NSSize(width: 150, height: 96)
        let aspect = pixel.width / max(pixel.height, 1)
        var size = NSSize(width: maxSize.width, height: maxSize.width / aspect)
        if size.height > maxSize.height {
            size = NSSize(width: maxSize.height * aspect, height: maxSize.height)
        }
        return NSSize(width: max(size.width, minSize.width).rounded(), height: max(size.height, minSize.height).rounded())
    }
}

/// Lets buttons respond to the first click even though the panel never activates the app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct QuickAccessView: View {
    let screenshot: Screenshot
    let size: NSSize
    let dismiss: () -> Void

    // `State` is used directly: the @State macro plugin ships only with Xcode.
    private let hoveringState = State(initialValue: false)
    private var hovering: Bool { hoveringState.wrappedValue }
    private let thumbnail: NSImage

    init(screenshot: Screenshot, size: NSSize, dismiss: @escaping () -> Void) {
        self.screenshot = screenshot
        self.size = size
        self.dismiss = dismiss
        thumbnail = NSImage(cgImage: screenshot.image, size: screenshot.pointSize)
    }

    var body: some View {
        ZStack {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()

            if hovering {
                Color.black.opacity(0.4)

                VStack(spacing: 8) {
                    Button("Copy", action: copy)
                    Button(screenshot.fileURL == nil ? "Save" : "Save As…", action: save)
                }
                .buttonStyle(PillButtonStyle())

                VStack {
                    HStack {
                        CornerButton(symbol: "xmark", help: "Close", action: dismiss)
                        Spacer()
                        CornerButton(symbol: "pencil", help: "Edit", action: edit)
                    }
                    Spacer()
                    HStack {
                        CornerButton(symbol: "pin", help: "Pin to Screen", action: pin)
                        Spacer()
                        if screenshot.fileURL != nil {
                            CornerButton(symbol: "folder", help: "Show in Finder", action: reveal)
                        }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
        )
        .onHover { hoveringState.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(count: 2, perform: edit)
        .onDrag { dragProvider() }
    }

    private func copy() {
        ImageExport.copyToPasteboard(screenshot.image, scale: screenshot.scale)
        dismiss()
    }

    private func save() {
        if screenshot.fileURL == nil {
            let url = ImageExport.newFileURL(for: screenshot.date)
            do {
                try ImageExport.write(screenshot.image, scale: screenshot.scale, to: url)
                screenshot.fileURL = url
                dismiss()
            } catch {
                NSAlert(error: error).runModal()
            }
        } else {
            let name = ImageExport.defaultFileName(for: screenshot.date, format: Preferences.imageFormat)
            if ImageExport.runSavePanel(for: screenshot.image, scale: screenshot.scale, suggestedName: name) != nil {
                dismiss()
            }
        }
    }

    private func edit() {
        EditorWindowController.open(screenshot)
        dismiss()
    }

    private func pin() {
        PinManager.shared.pin(screenshot)
        dismiss()
    }

    private func reveal() {
        guard let url = screenshot.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Drag the thumbnail into Finder, Mail, Slack, etc.
    private func dragProvider() -> NSItemProvider {
        if let url = screenshot.fileURL, FileManager.default.fileExists(atPath: url.path) {
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Loupe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(ImageExport.defaultFileName(for: screenshot.date, format: .png))
        try? ImageExport.write(screenshot.image, scale: screenshot.scale, to: url)
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black)
            .frame(width: 92, height: 26)
            .background(
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.75 : 0.95))
            )
    }
}

/// The thumbnail for a finished screen recording.
private struct RecordingQuickAccessView: View {
    let recording: Recording
    let size: NSSize
    let dismiss: () -> Void

    private let hoveringState = State(initialValue: false)
    private var hovering: Bool { hoveringState.wrappedValue }
    private let exportingState = State(initialValue: false)
    private var exporting: Bool { exportingState.wrappedValue }

    var body: some View {
        ZStack {
            if let thumbnail = recording.thumbnail {
                Image(nsImage: NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Color.black
            }

            if hovering || exporting {
                Color.black.opacity(0.4)

                if exporting {
                    ProgressView().controlSize(.small).colorScheme(.dark)
                } else {
                    VStack(spacing: 8) {
                        Button("Copy", action: copy)
                        Button(recording.isTemporary ? "Save" : "Save As…", action: save)
                    }
                    .buttonStyle(PillButtonStyle())
                }

                VStack {
                    HStack {
                        CornerButton(symbol: "xmark", help: "Close", action: close)
                        Spacer()
                        CornerButton(symbol: "play.fill", help: "Open", action: open)
                    }
                    Spacer()
                    HStack {
                        if !recording.isGIF {
                            CornerButton(symbol: "photo.stack", help: "Save as GIF", action: exportGIF)
                        }
                        Spacer()
                        CornerButton(symbol: "folder", help: "Show in Finder", action: reveal)
                    }
                }
                .padding(6)
                .disabled(exporting)
            } else {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.65)))
                    }
                }
                .padding(6)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
        )
        .onHover { hoveringState.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(count: 2, perform: open)
        .onDrag { NSItemProvider(contentsOf: recording.fileURL) ?? NSItemProvider() }
    }

    private var badge: String {
        let time = RecordingOverlay.format(recording.duration.rounded())
        return recording.isGIF ? "GIF · \(time)" : time
    }

    private func copy() {
        RecordingExport.copyToPasteboard(recording.fileURL)
        // An unsaved recording stays until it's saved or discarded.
        if !recording.isTemporary { dismiss() }
    }

    /// Closing an unsaved recording deletes it, so ask first.
    private func close() {
        guard recording.isTemporary else { return dismiss() }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "It hasn’t been saved, so it will be deleted."
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: recording.fileURL)
        dismiss()
    }

    private func save() {
        let format: RecordingFormat = recording.isGIF ? .gif : .mp4
        if recording.isTemporary {
            let url = RecordingExport.newFileURL(for: recording.date, format: format)
            do {
                try FileManager.default.moveItem(at: recording.fileURL, to: url)
                recording.fileURL = url
                recording.isTemporary = false
                dismiss()
                return
            } catch {
                // e.g. the save folder is on a drive that's gone: let the user pick somewhere else.
                NSAlert(error: error).runModal()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .gif ? .gif : .mpeg4Movie]
        panel.nameFieldStringValue = recording.fileURL.lastPathComponent
        panel.directoryURL = Preferences.saveDirectory
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Saving over the recording itself: it's already there.
            if Self.isSameFile(url, recording.fileURL) {
                dismiss()
                return
            }
            if FileManager.default.fileExists(atPath: url.path) {
                // Copy first, then swap, so a failed copy never loses the existing file.
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)
                try FileManager.default.copyItem(at: recording.fileURL, to: temporary)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.copyItem(at: recording.fileURL, to: url)
            }
            if recording.isTemporary {
                try? FileManager.default.removeItem(at: recording.fileURL)
                recording.fileURL = url
                recording.isTemporary = false
            }
            dismiss()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// True if both URLs point at the same file (also catches case-only differences
    /// on case-insensitive volumes, and symlinks).
    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath() {
            return true
        }
        let key = URLResourceKey.fileResourceIdentifierKey
        guard let idA = try? a.resourceValues(forKeys: [key]).fileResourceIdentifier,
              let idB = try? b.resourceValues(forKeys: [key]).fileResourceIdentifier else { return false }
        return idA.isEqual(idB)
    }

    private func open() {
        NSWorkspace.shared.open(recording.fileURL)
        if !recording.isTemporary { dismiss() }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([recording.fileURL])
    }

    /// Writes a GIF next to the movie and shows it as a new thumbnail.
    private func exportGIF() {
        let movie = recording.fileURL
        let directory = recording.isTemporary ? movie.deletingLastPathComponent() : Preferences.saveDirectory
        var url = directory.appendingPathComponent(RecordingExport.defaultFileName(for: recording.date, format: .gif))
        if !recording.isTemporary { url = RecordingExport.newFileURL(for: recording.date, format: .gif) }
        exportingState.wrappedValue = true
        let source = recording
        Task { @MainActor in
            do {
                try await GIFExporter.export(movie: movie, to: url)
                let gif = Recording(
                    fileURL: url, date: source.date, duration: source.duration,
                    thumbnail: source.thumbnail, scale: source.scale, isTemporary: source.isTemporary
                )
                exportingState.wrappedValue = false
                QuickAccessManager.shared.show(gif)
            } catch {
                exportingState.wrappedValue = false
                NSAlert(error: error).runModal()
            }
        }
    }
}

private struct CornerButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.95)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
