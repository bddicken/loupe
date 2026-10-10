import AppKit

/// One area-selection pass: a borderless overlay window per display, each
/// showing that display's frozen snapshot. The user selects on any of them.
@MainActor
final class SelectionSession {
    enum Mode {
        /// Drag and release to capture immediately.
        case quick
        /// Drag to create a selection, then move/resize it and press Return
        /// (or click Capture) to take the screenshot.
        case adjustable
    }

    struct Result {
        let image: CGImage
        let scale: CGFloat
    }

    let mode: Mode
    private let snapshots: [DisplaySnapshot]
    private let completion: (Result?) -> Void
    private var windows: [OverlayWindow] = []
    private var finished = false
    private var previousApp: NSRunningApplication?

    init(snapshots: [DisplaySnapshot], mode: Mode, completion: @escaping (Result?) -> Void) {
        self.snapshots = snapshots
        self.mode = mode
        self.completion = completion
    }

    func begin() {
        previousApp = NSWorkspace.shared.frontmostApplication
        windows = snapshots.map { OverlayWindow(snapshot: $0, session: self) }
        for window in windows {
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouseScreen = NSScreen.underMouse
        let keyWindow = windows.first { $0.snapshot.screen == mouseScreen } ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        keyWindow?.makeFirstResponder(keyWindow?.selectionView)
        NSCursor.crosshair.set()
    }

    /// Only one display can hold a selection at a time.
    func selectionDidBegin(in view: SelectionView) {
        for window in windows where window.selectionView !== view {
            window.selectionView.clearSelection()
        }
        if let window = view.window, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
    }

    func cancel() {
        finish(with: nil)
    }

    func capture(from view: SelectionView) {
        guard let image = view.capturedImage() else { return }
        finish(with: Result(image: image, scale: view.snapshot.scale))
    }

    private func finish(with result: Result?) {
        guard !finished else { return }
        finished = true
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        NSCursor.arrow.set()
        if let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
        completion(result)
    }
}

final class OverlayWindow: NSWindow {
    let snapshot: DisplaySnapshot
    let selectionView: SelectionView

    @MainActor
    init(snapshot: DisplaySnapshot, session: SelectionSession) {
        self.snapshot = snapshot
        selectionView = SelectionView(snapshot: snapshot, session: session)
        super.init(contentRect: snapshot.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)

        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(snapshot.screen.frame, display: false)

        // The frozen screen is a layer (composited on the GPU); the selection
        // chrome is drawn on top of it so redraws stay cheap.
        let background = NSView(frame: NSRect(origin: .zero, size: snapshot.screen.frame.size))
        background.wantsLayer = true
        background.layer?.contents = snapshot.image
        background.layer?.contentsGravity = .resize
        background.layer?.contentsScale = snapshot.scale
        selectionView.frame = background.bounds
        selectionView.autoresizingMask = [.width, .height]
        background.addSubview(selectionView)
        contentView = background
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
