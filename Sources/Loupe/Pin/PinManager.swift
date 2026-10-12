import AppKit

/// Screenshots pinned as always-on-top floating windows.
@MainActor
final class PinManager {
    static let shared = PinManager()

    private var panels: [PinnedPanel] = []

    private init() {}

    /// Kept out of later screenshots, like the quick access thumbnails.
    var windowNumbers: Set<Int> { Set(panels.map(\.windowNumber)) }

    func pin(_ screenshot: Screenshot) {
        let panel = PinnedPanel(screenshot: screenshot)
        panel.onClose = { [weak self, weak panel] in
            self?.panels.removeAll { $0 === panel }
        }
        panels.append(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
    }
}

/// Drag to move, scroll (or pinch) to resize, right-click for options, Esc or ✕ to close.
final class PinnedPanel: NSPanel {
    var onClose: (() -> Void)?
    private let screenshot: Screenshot
    private let imageView: PinnedImageView

    @MainActor
    init(screenshot: Screenshot) {
        self.screenshot = screenshot
        imageView = PinnedImageView(image: screenshot.image)

        let screen = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens[0]
        var size = screenshot.pointSize
        let maxSize = NSSize(width: screen.visibleFrame.width * 0.6, height: screen.visibleFrame.height * 0.6)
        let fit = min(1, maxSize.width / size.width, maxSize.height / size.height)
        size = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        let frame = NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        contentAspectRatio = size
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 60, height: 60)

        imageView.frame = NSRect(origin: .zero, size: size)
        imageView.autoresizingMask = [.width, .height]
        imageView.onClose = { [weak self] in self?.close() }
        imageView.menuProvider = { [weak self] in self?.makeMenu() }
        contentView = imageView
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            close()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copyImage()
        } else {
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        zoom(by: 1 + delta)
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification)
    }

    /// Resizes around the window's center, keeping the aspect ratio.
    private func zoom(by factor: CGFloat) {
        guard factor > 0 else { return }
        var size = NSSize(width: frame.width * factor, height: frame.height * factor)
        if size.width < minSize.width || size.height < minSize.height { return }
        let maxWidth = (screen?.frame.width ?? 4000) * 1.5
        if size.width > maxWidth {
            size = NSSize(width: maxWidth, height: maxWidth * frame.height / frame.width)
        }
        let newFrame = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        setFrame(newFrame, display: true)
    }

    @MainActor
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open in Editor", action: #selector(openInEditor), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "").target = self

        let opacity = NSMenu()
        for percent in [100, 75, 50, 25] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = Int((alphaValue * 100).rounded()) == percent ? .on : .off
            opacity.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacity
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closeFromMenu), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() {
        MainActor.assumeIsolated { ImageExport.copyToPasteboard(screenshot.image, scale: screenshot.scale) }
    }

    @objc private func openInEditor() {
        // Its own copy: two editors sharing one Screenshot would also share where it's
        // saved, so saving in one could overwrite what the other saved.
        let copy = Screenshot(image: screenshot.image, scale: screenshot.scale, fileURL: screenshot.fileURL, date: screenshot.date)
        MainActor.assumeIsolated { EditorWindowController.open(copy) }
    }

    @objc private func actualSize() {
        let size = screenshot.pointSize
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        alphaValue = CGFloat(sender.tag) / 100
    }

    @objc private func closeFromMenu() {
        close()
    }
}

/// Shows the image and a close button on hover.
private final class PinnedImageView: NSView {
    var onClose: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private let closeButton: NSButton

    init(image: CGImage) {
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspect
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor

        closeButton.isBordered = false
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.6)]))
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.isHidden = true
        closeButton.frame = NSRect(x: 6, y: 0, width: 24, height: 24)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        closeButton.frame.origin = NSPoint(x: 6, y: bounds.height - 30)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    @objc private func closePressed() { onClose?() }
}
