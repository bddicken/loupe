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
        /// Like `adjustable`, but picks an area to record: a click selects a
        /// window's frame, and Return with no selection picks the whole display.
        case record

        /// The selection stays up to be moved and resized before confirming.
        var isAdjustable: Bool { self != .quick }
    }

    enum Result {
        case image(CGImage, scale: CGFloat, area: CaptureArea)
        case window(CGWindowID)
        /// The confirmed selection, without pixels (`record` mode).
        case area(CaptureArea)
    }

    let mode: Mode
    /// Windows that can be clicked to capture, frontmost first.
    let windows: [WindowInfo]
    private let snapshots: [DisplaySnapshot]
    private let completion: (Result?) -> Void
    private var overlays: [OverlayWindow] = []
    private var finished = false
    private var previousApp: NSRunningApplication?

    init(snapshots: [DisplaySnapshot], windows: [WindowInfo], mode: Mode, completion: @escaping (Result?) -> Void) {
        self.snapshots = snapshots
        self.windows = windows
        self.mode = mode
        self.completion = completion
    }

    func begin() {
        previousApp = NSWorkspace.shared.frontmostApplication
        overlays = snapshots.map { OverlayWindow(snapshot: $0, session: self) }
        for window in overlays {
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouseScreen = NSScreen.underMouse
        let keyWindow = overlays.first { $0.snapshot.screen == mouseScreen } ?? overlays.first
        keyWindow?.makeKeyAndOrderFront(nil)
        keyWindow?.makeFirstResponder(keyWindow?.selectionView)
        NSCursor.crosshair.set()
    }

    /// Only one display can hold a selection at a time.
    func selectionDidBegin(in view: SelectionView) {
        for window in overlays where window.selectionView !== view {
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
        if mode == .record {
            guard let selection = view.selection, let displayID = view.snapshot.screen.displayID else { return }
            finish(with: .area(CaptureArea(displayID: displayID, rect: selection)))
            return
        }
        guard let image = view.capturedImage(), let selection = view.selection,
              let displayID = view.snapshot.screen.displayID else { return }
        let area = CaptureArea(displayID: displayID, rect: selection)
        finish(with: .image(image, scale: view.snapshot.scale, area: area))
    }

    func captureWindow(_ window: WindowInfo) {
        finish(with: .window(window.id))
    }

    private func finish(with result: Result?) {
        guard !finished else { return }
        finished = true
        for window in overlays {
            window.orderOut(nil)
        }
        overlays.removeAll()
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
