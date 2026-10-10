import AppKit

/// Draws the selection rectangle, handles, size label, crosshair and
/// magnifier over a frozen display snapshot, and handles mouse/keyboard input.
final class SelectionView: NSView {
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum DragState {
        case none
        case creating(start: NSPoint)
        case moving(start: NSPoint, original: NSRect)
        case resizing(Handle, start: NSPoint, original: NSRect)
    }

    let snapshot: DisplaySnapshot
    private weak var session: SelectionSession?
    private let mode: SelectionSession.Mode

    private var selection: NSRect?
    private var dragState: DragState = .none
    private var mouseLocation: NSPoint?
    private let buttonBar: NSStackView
    /// Windows on this display in view coordinates, frontmost first.
    private let windows: [(info: WindowInfo, frame: NSRect)]
    private var hoveredWindow: (info: WindowInfo, frame: NSRect)?

    private let handleRadius: CGFloat = 4.5
    private let handleHitSlop: CGFloat = 8
    private let minimumSize: CGFloat = 4

    @MainActor
    init(snapshot: DisplaySnapshot, session: SelectionSession) {
        self.snapshot = snapshot
        self.session = session
        mode = session.mode
        let screenFrame = snapshot.screen.frame
        windows = session.windows.compactMap { info in
            let frame = info.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            return frame.intersects(NSRect(origin: .zero, size: screenFrame.size)) ? (info, frame) : nil
        }

        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        let capture = NSButton(title: "Capture", target: nil, action: nil)
        capture.keyEquivalent = "" // Return is handled in keyDown.
        capture.bezelColor = .controlAccentColor
        buttonBar = NSStackView(views: [cancel, capture])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 8
        buttonBar.isHidden = true

        super.init(frame: .zero)

        cancel.target = self
        cancel.action = #selector(cancelPressed)
        capture.target = self
        capture.action = #selector(capturePressed)
        addSubview(buttonBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
    }

    // MARK: - Public

    func clearSelection() {
        selection = nil
        dragState = .none
        updateButtonBar()
        needsDisplay = true
    }

    /// The selected region cropped from the snapshot at full pixel resolution.
    func capturedImage() -> CGImage? {
        guard let selection, selection.width >= 1, selection.height >= 1 else { return nil }
        let scale = snapshot.scale
        let pixelRect = CGRect(
            x: (selection.minX * scale).rounded(),
            y: ((bounds.height - selection.maxY) * scale).rounded(),
            width: (selection.width * scale).rounded(),
            height: (selection.height * scale).rounded()
        )
        guard let cropped = snapshot.image.cropping(to: pixelRect) else { return nil }
        return cropped.detachedCopy() ?? cropped
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = clamp(snap(convert(event.locationInWindow, from: nil)))
        mouseLocation = point

        if mode == .adjustable, let selection {
            if let handle = handle(at: point, in: selection) {
                dragState = .resizing(handle, start: point, original: selection)
                return redraw()
            }
            if selection.contains(point) {
                if event.clickCount == 2 {
                    session?.capture(from: self)
                    return
                }
                dragState = .moving(start: point, original: selection)
                NSCursor.closedHand.set()
                return redraw()
            }
        }

        session?.selectionDidBegin(in: self)
        selection = NSRect(origin: point, size: .zero)
        dragState = .creating(start: point)
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(snap(convert(event.locationInWindow, from: nil)))
        mouseLocation = point

        switch dragState {
        case .none:
            return
        case let .creating(start):
            var dx = point.x - start.x
            var dy = point.y - start.y
            if event.modifierFlags.contains(.shift) {
                let side = max(abs(dx), abs(dy))
                dx = side * (dx < 0 ? -1 : 1)
                dy = side * (dy < 0 ? -1 : 1)
            }
            selection = NSRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy))
                .intersection(bounds)
        case let .moving(start, original):
            var moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            moved.origin.x = min(max(moved.origin.x, bounds.minX), bounds.maxX - moved.width)
            moved.origin.y = min(max(moved.origin.y, bounds.minY), bounds.maxY - moved.height)
            selection = moved
        case let .resizing(handle, start, original):
            selection = resized(original, handle: handle, dx: point.x - start.x, dy: point.y - start.y)
        }
        redraw()
    }

    override func mouseUp(with event: NSEvent) {
        let wasCreating: Bool
        if case .creating = dragState { wasCreating = true } else { wasCreating = false }
        dragState = .none

        if let selection, selection.width < minimumSize || selection.height < minimumSize {
            // A click (no drag) picks the window under the cursor.
            let point = convert(event.locationInWindow, from: nil)
            if wasCreating, let window = window(at: point) {
                if mode == .quick {
                    session?.captureWindow(window.info)
                    return
                }
                self.selection = window.frame.intersection(bounds)
                hoveredWindow = nil
                updateCursor(at: point)
                redraw()
                return
            }
            clearSelection()
            return
        }
        if wasCreating, mode == .quick, selection != nil {
            session?.capture(from: self)
            return
        }
        updateCursor(at: convert(event.locationInWindow, from: nil))
        redraw()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = bounds.contains(point) ? snap(point) : nil
        hoveredWindow = selection == nil ? window(at: point) : nil
        updateCursor(at: point)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouseLocation = nil
        hoveredWindow = nil
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        session?.cancel()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape
            session?.cancel()
        case 36, 76: // Return, Enter
            if selection != nil { session?.capture(from: self) }
        case 123, 124, 125, 126: // Arrows nudge the selection.
            guard var selection, case .none = dragState else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1 / snapshot.scale
            switch Int(event.keyCode) {
            case 123: selection.origin.x -= step
            case 124: selection.origin.x += step
            case 125: selection.origin.y -= step
            default: selection.origin.y += step
            }
            selection.origin.x = min(max(selection.origin.x, 0), bounds.width - selection.width)
            selection.origin.y = min(max(selection.origin.y, 0), bounds.height - selection.height)
            self.selection = selection
            redraw()
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func cancelPressed() { session?.cancel() }
    @objc private func capturePressed() { session?.capture(from: self) }

    // MARK: - Geometry

    private func window(at point: NSPoint) -> (info: WindowInfo, frame: NSRect)? {
        windows.first { $0.frame.contains(point) }
    }

    private func snap(_ point: NSPoint) -> NSPoint {
        let scale = snapshot.scale
        return NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    private func clamp(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func handlePoint(_ handle: Handle, in rect: NSRect) -> NSPoint {
        switch handle {
        case .topLeft: NSPoint(x: rect.minX, y: rect.maxY)
        case .top: NSPoint(x: rect.midX, y: rect.maxY)
        case .topRight: NSPoint(x: rect.maxX, y: rect.maxY)
        case .right: NSPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: NSPoint(x: rect.maxX, y: rect.minY)
        case .bottom: NSPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: NSPoint(x: rect.minX, y: rect.minY)
        case .left: NSPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handle(at point: NSPoint, in rect: NSRect) -> Handle? {
        Handle.allCases.first { handle in
            let p = handlePoint(handle, in: rect)
            return abs(p.x - point.x) <= handleHitSlop && abs(p.y - point.y) <= handleHitSlop
        }
    }

    private func resized(_ rect: NSRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> NSRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX += dx; maxY += dy
        case .top: maxY += dy
        case .topRight: maxX += dx; maxY += dy
        case .right: maxX += dx
        case .bottomRight: maxX += dx; minY += dy
        case .bottom: minY += dy
        case .bottomLeft: minX += dx; minY += dy
        case .left: minX += dx
        }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
            .intersection(bounds)
    }

    private func updateCursor(at point: NSPoint) {
        guard mode == .adjustable, let selection, case .none = dragState else {
            if case .moving = dragState { return }
            NSCursor.crosshair.set()
            return
        }
        if let handle = handle(at: point, in: selection) {
            switch handle {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        } else if selection.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func redraw() {
        updateButtonBar()
        needsDisplay = true
    }

    private func updateButtonBar() {
        guard mode == .adjustable, let selection, selection.width >= minimumSize, case .none = dragState else {
            buttonBar.isHidden = true
            return
        }
        buttonBar.isHidden = false
        let size = buttonBar.fittingSize
        var origin = NSPoint(x: selection.midX - size.width / 2, y: selection.minY - size.height - 12)
        if origin.y < bounds.minY + 8 {
            origin.y = selection.maxY + 12
            if origin.y + size.height > bounds.maxY - 8 {
                origin.y = selection.minY + 12
            }
        }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        buttonBar.frame = NSRect(origin: origin, size: size)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if let selection, selection.width > 0, selection.height > 0 {
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill()
            dim.fill()

            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            NSColor.white.withAlphaComponent(0.9).setStroke()
            border.stroke()

            let isDragging: Bool
            if case .none = dragState { isDragging = false } else { isDragging = true }
            if mode == .adjustable, !isDragging {
                drawHandles(for: selection, in: context)
            }
            drawSizeLabel(for: selection)
        }

        if selection == nil, let hoveredWindow {
            drawWindowHighlight(hoveredWindow)
        }

        guard let mouseLocation else { return }
        let showsMagnifier: Bool
        switch dragState {
        case .none: showsMagnifier = selection == nil
        case .creating, .resizing: showsMagnifier = true
        case .moving: showsMagnifier = false
        }
        if selection == nil {
            drawCrosshair(at: mouseLocation)
        }
        if showsMagnifier {
            drawMagnifier(at: mouseLocation, in: context)
        }
    }

    private func drawWindowHighlight(_ window: (info: WindowInfo, frame: NSRect)) {
        let frame = window.frame.intersection(bounds)
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: frame))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.3).setFill()
        dim.fill()

        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        frame.fill()
        let border = NSBezierPath(rect: frame.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        let label = pill(window.info.ownerName.isEmpty ? "Click to capture window" : "\(window.info.ownerName) — click to capture")
        let origin = NSPoint(
            x: min(max(frame.midX - label.size.width / 2, bounds.minX + 4), bounds.maxX - label.size.width - 4),
            y: min(max(frame.midY - label.size.height / 2, bounds.minY + 4), bounds.maxY - label.size.height - 4)
        )
        label.draw(at: origin)
    }

    private func drawHandles(for rect: NSRect, in context: CGContext) {
        context.saveGState()
        context.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        for handle in Handle.allCases {
            let p = handlePoint(handle, in: rect)
            let circle = NSBezierPath(ovalIn: NSRect(x: p.x - handleRadius, y: p.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2))
            NSColor.white.setFill()
            circle.fill()
        }
        context.restoreGState()
    }

    private func drawSizeLabel(for rect: NSRect) {
        let scale = snapshot.scale
        let text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
        let label = pill(text)
        var origin = NSPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + label.size.height > bounds.maxY {
            origin = NSPoint(x: rect.minX + 6, y: rect.maxY - label.size.height - 6)
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - label.size.width - 4)
        label.draw(at: origin)
    }

    private func drawCrosshair(at point: NSPoint) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: point.y + 0.5))
        path.line(to: NSPoint(x: bounds.maxX, y: point.y + 0.5))
        path.move(to: NSPoint(x: point.x + 0.5, y: bounds.minY))
        path.line(to: NSPoint(x: point.x + 0.5, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.stroke()
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    /// The loupe: a zoomed-in view of the pixels under the cursor.
    private func drawMagnifier(at point: NSPoint, in context: CGContext) {
        let pixelsAcross = 15
        let cell: CGFloat = 8
        let side = CGFloat(pixelsAcross) * cell
        let scale = snapshot.scale

        let centerX = Int((point.x * scale).rounded(.down))
        let centerY = Int(((bounds.height - point.y) * scale).rounded(.down))
        let half = pixelsAcross / 2
        let requested = CGRect(x: centerX - half, y: centerY - half, width: pixelsAcross, height: pixelsAcross)
        let available = requested.intersection(CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height))

        var frame = NSRect(x: point.x + 24, y: point.y - 24 - side, width: side, height: side)
        if frame.maxX > bounds.maxX - 4 { frame.origin.x = point.x - 24 - side }
        if frame.minY < bounds.minY + 30 { frame.origin.y = point.y + 24 }

        let shape = CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        context.addPath(shape)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        if !available.isNull, let pixels = snapshot.image.cropping(to: available) {
            context.interpolationQuality = .none
            let destWidth = available.width * cell
            let destHeight = available.height * cell
            let destX = frame.minX + (available.minX - requested.minX) * cell
            let destMaxY = frame.maxY - (available.minY - requested.minY) * cell
            context.draw(pixels, in: CGRect(x: destX, y: destMaxY - destHeight, width: destWidth, height: destHeight))
        }
        let centerCell = CGRect(x: frame.minX + CGFloat(half) * cell, y: frame.minY + CGFloat(half) * cell, width: cell, height: cell)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(2)
        context.stroke(centerCell.insetBy(dx: -1, dy: -1))
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(centerCell.insetBy(dx: -0.5, dy: -0.5))
        context.restoreGState()

        context.addPath(shape)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1.5)
        context.strokePath()

        let label = pill("\(Int(point.x.rounded())), \(Int((bounds.height - point.y).rounded()))")
        label.draw(at: NSPoint(x: frame.midX - label.size.width / 2, y: frame.minY - label.size.height - 4))
    }

    private func pill(_ text: String) -> Pill {
        Pill(text: text)
    }
}

/// A small rounded label drawn directly into the current context.
private struct Pill {
    let attributed: NSAttributedString
    let size: NSSize
    private let padding = NSSize(width: 6, height: 2)

    init(text: String) {
        attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let textSize = attributed.size()
        size = NSSize(width: ceil(textSize.width) + padding.width * 2, height: ceil(textSize.height) + padding.height * 2)
    }

    func draw(at origin: NSPoint) {
        let rect = NSRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        attributed.draw(at: NSPoint(x: origin.x + padding.width, y: origin.y + padding.height))
    }
}

extension CGImage {
    /// Copies the pixels into a standalone bitmap so a small crop doesn't keep
    /// the whole full-display snapshot alive in memory.
    func detachedCopy() -> CGImage? {
        let colorSpace = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
