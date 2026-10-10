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
        let panel = QuickAccessPanel(screenshot: screenshot)
        panel.onDismiss = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.dismiss(panel)
        }
        panels.insert(panel, at: 0)
        while panels.count > maxPanels {
            panels.removeLast().orderOut(nil)
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

    @MainActor
    init(screenshot: Screenshot) {
        let size = QuickAccessPanel.thumbnailSize(for: screenshot)
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

        let view = QuickAccessView(
            screenshot: screenshot,
            size: size,
            dismiss: { [weak self] in self?.onDismiss?() }
        )
        contentView = FirstMouseHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { true }

    private static func thumbnailSize(for screenshot: Screenshot) -> NSSize {
        let maxSize = NSSize(width: 220, height: 150)
        let minSize = NSSize(width: 150, height: 96)
        let pixel = NSSize(width: screenshot.image.width, height: screenshot.image.height)
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
