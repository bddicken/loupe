import AppKit
import SwiftUI

/// Hosts the AppKit annotation canvas over the editor's preview image.
struct AnnotationCanvas: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    /// Source pixels → view points.
    let transform: CGAffineTransform
    /// The screenshot's area in view points (excludes backdrop padding).
    let contentRect: CGRect

    func makeNSView(context: Context) -> AnnotationCanvasView {
        AnnotationCanvasView(model: model)
    }

    func updateNSView(_ view: AnnotationCanvasView, context: Context) {
        view.update(transform: transform, contentRect: contentRect)
    }
}

/// Draws annotations live and turns mouse/keyboard input into annotation edits.
/// Uses the same AnnotationRenderer as export, so what you see is what you get.
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    private let model: EditorModel
    private var transform: CGAffineTransform = .identity
    private var contentRect: CGRect = .zero
    private var lastTool: AnnotationTool?

    private var draft: Annotation? {
        didSet {
            // Blur/pixelate drafts are rendered by the image pipeline so they preview live.
            let regionDraft = draft?.kind.isRegionEffect == true ? draft : nil
            MainActor.assumeIsolated {
                if model.regionDraft != regionDraft { model.regionDraft = regionDraft }
            }
        }
    }
    private var moving: (id: UUID, last: CGPoint, didCheckpoint: Bool)?
    /// A text pressed with the Text tool: a click (no drag) edits it on mouse up; a drag moves it.
    private var editTextOnClick: UUID?

    private enum Handle {
        case endpoint(Int)
        case corner(Int) // 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left
        case scale(Int) // Bounding-box corner that scales text, counters and freehand strokes.
        case textWidth(trailing: Bool) // A text box's left or right edge: sets the width it wraps at.
    }
    /// The fixed point while dragging a box corner is the opposite corner.
    private var resizing: (id: UUID, handle: Handle, anchor: CGPoint, original: Annotation, didCheckpoint: Bool)?
    private let handleRadius: CGFloat = 4.5

    private var textView: NSTextView?
    /// The text annotation being edited, and whether it already exists in the model.
    private var editing: (annotation: Annotation, isNew: Bool)?
    /// A text box being dragged out with the Text tool (view points); a click makes an auto-width label instead.
    private var textDrag: (start: CGPoint, current: CGPoint)?
    /// Shortest drag that makes a fixed-width text box rather than a click.
    private let textDragThreshold: CGFloat = 12

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        MainActor.assumeIsolated {
            model.commitTextEditing = { [weak self] in self?.endTextEditing() }
            model.focusCanvas = { [weak self] in
                guard let self else { return }
                self.endTextEditing()
                self.window?.makeFirstResponder(self)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.textView == nil else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    @MainActor
    func update(transform: CGAffineTransform, contentRect: CGRect) {
        self.transform = transform
        self.contentRect = contentRect
        if lastTool != model.tool {
            lastTool = model.tool
            if model.tool != .text { endTextEditing() }
            window?.invalidateCursorRects(for: self)
        }
        repositionTextView()
        // The selected text's width handles get a resize cursor.
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: - Coordinates

    private var viewScale: CGFloat { max(hypot(transform.a, transform.b), 0.0001) }

    private func sourcePoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil).applying(transform.inverted())
    }

    /// Hit tolerance of ~6 view points, expressed in source pixels.
    private var tolerance: CGFloat { 6 / viewScale }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let annotations = MainActor.assumeIsolated { model.state.annotations }
        let selectedID = MainActor.assumeIsolated { model.selectedAnnotationID }

        context.saveGState()
        context.clip(to: contentRect)
        context.concatenate(transform)
        for annotation in annotations where annotation.id != editing?.annotation.id {
            AnnotationRenderer.draw(annotation, in: context, orientation: transform)
        }
        if let draft {
            AnnotationRenderer.draw(draft, in: context, orientation: transform)
        }
        context.restoreGState()

        if let draft, draft.kind.isRegionEffect {
            strokeDashed(draft.rect.applying(transform), color: .white)
        }
        if let textDrag {
            strokeDashed(Self.rect(textDrag.start, textDrag.current), color: .controlAccentColor)
        }
        if let textView {
            // The box being typed into, so its extent (and wrap width) is clear.
            strokeDashed(textView.frame.insetBy(dx: -4, dy: -2), color: .controlAccentColor)
        }
        if let selected = annotations.first(where: { $0.id == selectedID }), selected.id != editing?.annotation.id {
            let handles = self.handles(for: selected)
            if case .scale = handles.first?.handle {
                strokeDashed(AnnotationRenderer.bounds(selected, orientation: transform).applying(transform), color: .controlAccentColor)
            }
            drawHandles(handles.map { $0.point.applying(transform) }, in: context)
        }
    }

    private func drawHandles(_ points: [CGPoint], in context: CGContext) {
        context.saveGState()
        context.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        for point in points {
            let circle = NSBezierPath(ovalIn: NSRect(
                x: point.x - handleRadius, y: point.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2
            ))
            NSColor.white.setFill()
            circle.fill()
            NSColor.controlAccentColor.setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
        }
        context.restoreGState()
    }

    /// Endpoint handles for lines/arrows, corner handles for boxes (source pixels).
    private func handles(for annotation: Annotation) -> [(handle: Handle, point: CGPoint)] {
        switch annotation.kind {
        case .arrow, .line:
            return [(.endpoint(0), annotation.start), (.endpoint(1), annotation.end)]
        case .rectangle, .ellipse, .blur, .pixelate, .redact:
            let r = annotation.rect
            return [
                (.corner(0), CGPoint(x: r.minX, y: r.minY)),
                (.corner(1), CGPoint(x: r.maxX, y: r.minY)),
                (.corner(2), CGPoint(x: r.maxX, y: r.maxY)),
                (.corner(3), CGPoint(x: r.minX, y: r.maxY)),
            ]
        case .text, .step, .pen, .highlighter:
            let r = AnnotationRenderer.bounds(annotation, orientation: transform)
            var handles: [(handle: Handle, point: CGPoint)] = [
                (.scale(0), CGPoint(x: r.minX, y: r.minY)),
                (.scale(1), CGPoint(x: r.maxX, y: r.minY)),
                (.scale(2), CGPoint(x: r.maxX, y: r.maxY)),
                (.scale(3), CGPoint(x: r.minX, y: r.maxY)),
            ]
            if annotation.kind == .text {
                // Text reads upright on screen, so its box's edges are found in view space.
                let box = textBox(annotation)
                let toSource = transform.inverted()
                handles.append((.textWidth(trailing: false), CGPoint(x: box.minX, y: box.midY).applying(toSource)))
                handles.append((.textWidth(trailing: true), CGPoint(x: box.maxX, y: box.midY).applying(toSource)))
            }
            return handles
        }
    }

    /// A text annotation's box in view points (text always reads upright on screen).
    private func textBox(_ annotation: Annotation) -> CGRect {
        let size = AnnotationRenderer.textSize(annotation)
        return CGRect(origin: annotation.start.applying(transform), size: CGSize(width: size.width * viewScale, height: size.height * viewScale))
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    @MainActor
    private func handleHit(atViewPoint point: CGPoint) -> (annotation: Annotation, handle: Handle, point: CGPoint)? {
        guard let selected = model.selectedAnnotation else { return nil }
        for (handle, sourcePoint) in handles(for: selected) {
            let p = sourcePoint.applying(transform)
            if hypot(p.x - point.x, p.y - point.y) <= handleRadius + 4 {
                return (selected, handle, sourcePoint)
            }
        }
        return nil
    }

    private func strokeDashed(_ rect: CGRect, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.4).setStroke()
        path.stroke()
        path.setLineDash([5, 4], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }

    override func resetCursorRects() {
        let (tool, selected) = MainActor.assumeIsolated { (model.tool, model.selectedAnnotation) }
        let cursor: NSCursor = switch tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(contentRect, cursor: cursor)
        if let selected, selected.kind == .text, textView == nil {
            let box = textBox(selected)
            let size = (handleRadius + 4) * 2
            for x in [box.minX, box.maxX] {
                addCursorRect(CGRect(x: x - size / 2, y: box.midY - size / 2, width: size, height: size), cursor: .resizeLeftRight)
            }
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { handleMouseDown(event) }
    }

    @MainActor
    private func handleMouseDown(_ event: NSEvent) {
        endTextEditing()
        window?.makeFirstResponder(self)
        let point = sourcePoint(event)

        if let (selected, handle, _) = handleHit(atViewPoint: convert(event.locationInWindow, from: nil)) {
            let anchor: CGPoint
            switch handle {
            case let .endpoint(index): anchor = selected.points[1 - index]
            case let .corner(index), let .scale(index): anchor = handles(for: selected)[(index + 2) % 4].point
            case .textWidth: anchor = selected.start
            }
            resizing = (selected.id, handle, anchor, selected, false)
            return
        }

        // With a drawing tool, clicking an existing annotation selects it
        // (⌥ forces drawing on top instead).
        let isSelectTool = model.tool == .select
        let hit = isSelectTool || !event.modifierFlags.contains(.option) ? annotation(at: point, interior: isSelectTool) : nil

        if let hit {
            model.selectedAnnotationID = hit.id
            if hit.kind == .text, event.clickCount == 2 {
                beginTextEditing(hit, isNew: false)
            } else {
                // Any shape, text included, can be dragged to move it.
                moving = (hit.id, point, false)
                if hit.kind == .text, model.tool == .text { editTextOnClick = hit.id }
            }
            needsDisplay = true
            return
        }

        // Clicking away from the selected layer deselects it, so toolbar changes
        // go back to styling the next annotation instead of that layer.
        model.selectedAnnotationID = nil

        switch model.tool {
        case .select:
            break
        case .text:
            // A click makes an auto-width label; a drag, a box that wraps at its width (on mouse up).
            let viewPoint = convert(event.locationInWindow, from: nil)
            textDrag = (viewPoint, viewPoint)
        case .step:
            model.addAnnotation(model.newAnnotation(.step, points: [point]))
        default:
            if let kind = model.tool.kind {
                draft = model.newAnnotation(kind, points: kind.isFreehand ? [point] : [point, point])
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        MainActor.assumeIsolated {
            let point = sourcePoint(event)
            if var resize = resizing {
                if !resize.didCheckpoint {
                    model.checkpoint()
                    resize.didCheckpoint = true
                    resizing = resize
                }
                model.updateAnnotation(resize.id, checkpoint: false) { annotation in
                    let target = event.modifierFlags.contains(.shift)
                        ? constrained(point, from: resize.anchor, kind: annotation.kind)
                        : point
                    switch resize.handle {
                    case let .endpoint(index): annotation.points[index] = target
                    case .corner: annotation.points = [resize.anchor, target]
                    case let .textWidth(trailing):
                        // In view space, where the text box is upright; at least about one character wide.
                        let box = textBox(resize.original)
                        let x = convert(event.locationInWindow, from: nil).x
                        let minimum = resize.original.fontSize * viewScale
                        if trailing {
                            annotation.textWidth = max(x - box.minX, minimum) / viewScale
                        } else {
                            let left = min(x, box.maxX - minimum)
                            annotation.textWidth = (box.maxX - left) / viewScale
                            annotation.points = [CGPoint(x: left, y: box.minY).applying(transform.inverted())]
                        }
                    case .scale:
                        // Uniform scale, keeping the opposite corner fixed.
                        let box = AnnotationRenderer.bounds(resize.original, orientation: transform)
                        let factor = max(
                            abs(point.x - resize.anchor.x) / max(box.width, 1),
                            abs(point.y - resize.anchor.y) / max(box.height, 1),
                            0.1
                        )
                        annotation = resize.original.scaled(by: factor, about: resize.anchor)
                    }
                }
                return
            }
            if var move = moving {
                if !move.didCheckpoint {
                    model.checkpoint()
                    move.didCheckpoint = true
                }
                model.moveAnnotation(move.id, dx: point.x - move.last.x, dy: point.y - move.last.y)
                move.last = point
                moving = move
                return
            }
            if var drag = textDrag {
                drag.current = convert(event.locationInWindow, from: nil)
                textDrag = drag
                needsDisplay = true
                return
            }
            guard var draft else { return }
            if draft.kind.isFreehand {
                if let last = draft.points.last, hypot(point.x - last.x, point.y - last.y) * viewScale >= 1 {
                    draft.points.append(point)
                }
            } else {
                draft.points[1] = event.modifierFlags.contains(.shift) ? constrained(point, from: draft.start, kind: draft.kind) : point
            }
            self.draft = draft
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated {
            let wasDragged = moving?.didCheckpoint ?? false
            moving = nil
            resizing = nil
            if let id = editTextOnClick {
                editTextOnClick = nil
                if !wasDragged, let text = model.state.annotations.first(where: { $0.id == id }) {
                    beginTextEditing(text, isNew: false)
                    return
                }
            }
            if let drag = textDrag {
                textDrag = nil
                let box = Self.rect(drag.start, drag.current)
                var text = model.newAnnotation(.text, points: [box.origin.applying(transform.inverted())])
                if box.width >= textDragThreshold {
                    text.textWidth = box.width / viewScale
                } else {
                    text.points = [drag.start.applying(transform.inverted())]
                }
                beginTextEditing(text, isNew: true)
                needsDisplay = true
                return
            }
            guard let draft else { return }
            self.draft = nil
            let isMeaningful = draft.kind.isFreehand
                ? draft.points.count > 1
                : hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) * viewScale >= 3
            if isMeaningful {
                model.addAnnotation(draft)
            }
            needsDisplay = true
        }
    }

    /// Shift: squares for boxes, 45° steps for lines and arrows.
    private func constrained(_ point: CGPoint, from start: CGPoint, kind: Annotation.Kind) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        if kind.isBoxed {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + side * (dx < 0 ? -1 : 1), y: start.y + side * (dy < 0 ? -1 : 1))
        }
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    /// The topmost annotation under `point`. With `interior`, a click inside a
    /// hollow box also counts, preferring the smallest box so shapes nested
    /// inside a larger one stay reachable.
    @MainActor
    private func annotation(at point: CGPoint, interior: Bool) -> Annotation? {
        let annotations = model.state.annotations
        if let hit = annotations.reversed().first(where: { AnnotationRenderer.hitTest($0, at: point, tolerance: tolerance, orientation: transform) }) {
            return hit
        }
        guard interior else { return nil }
        return annotations
            .filter { AnnotationRenderer.hitTest($0, at: point, tolerance: tolerance, interior: true, orientation: transform) }
            .min { area(AnnotationRenderer.bounds($0, orientation: transform)) < area(AnnotationRenderer.bounds($1, orientation: transform)) }
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let handled = MainActor.assumeIsolated { handleKey(event) }
        if !handled { super.keyDown(with: event) }
    }

    @MainActor
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        if modifiers == .command, event.keyCode == 30 || event.keyCode == 33 { // ⌘] / ⌘[ (⇧ = to front/back)
            let shift = event.modifierFlags.contains(.shift)
            let forward = event.keyCode == 30
            model.moveSelectedAnnotation(forward ? (shift ? .front : .forward) : (shift ? .back : .backward))
            return true
        }
        guard modifiers.isEmpty else { return false }

        switch Int(event.keyCode) {
        case 51, 117: // Delete, Forward Delete
            model.deleteSelectedAnnotation()
            return true
        case 53: // Escape
            model.selectedAnnotationID = nil
            return true
        case 123, 124, 125, 126: // Arrows nudge the selection by 1pt (⇧ = 10pt).
            guard let id = model.selectedAnnotationID else { return false }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let (dx, dy): (CGFloat, CGFloat) = switch Int(event.keyCode) {
            case 123: (-step, 0)
            case 124: (step, 0)
            case 125: (0, step)
            default: (0, -step)
            }
            // Convert the view-space nudge into source space (handles rotation).
            let inverse = transform.inverted()
            let origin = CGPoint.zero.applying(inverse)
            let moved = CGPoint(x: dx, y: dy).applying(inverse)
            model.checkpoint()
            model.moveAnnotation(id, dx: moved.x - origin.x, dy: moved.y - origin.y)
            return true
        default:
            break
        }

        guard let character = event.charactersIgnoringModifiers?.lowercased().first else { return false }
        if character == "c" {
            model.beginCrop()
            return true
        }
        if let tool = AnnotationTool.allCases.first(where: { $0.key == character }) {
            model.tool = tool
            return true
        }
        return false
    }

    // MARK: - Text editing

    @MainActor
    private func beginTextEditing(_ annotation: Annotation, isNew: Bool) {
        endTextEditing()
        editing = (annotation, isNew)

        // A multi-line editor sized to its text, so everything typed stays visible; a
        // text box with a width wraps at it. Return starts a new line; Esc or clicking
        // elsewhere finishes.
        let textView = NSTextView(frame: .zero)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        if let container = textView.textContainer {
            // Like the rendered text: no padding, wrapping only at a set width.
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
        }
        textView.layoutManager?.usesFontLeading = false
        textView.string = annotation.text
        textView.textColor = annotation.color.nsColor
        textView.insertionPointColor = annotation.color.nsColor
        textView.delegate = self
        addSubview(textView)
        self.textView = textView
        repositionTextView()
        window?.makeFirstResponder(textView)
        textView.selectAll(nil)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Sizes and places the editor to show all of the text. It lays the text out at its
    /// real size and is scaled to the zoom, so it wraps exactly like the drawn text
    /// (the system font's spacing changes with point size).
    private func repositionTextView() {
        guard let textView, let annotation = editing?.annotation,
              let container = textView.textContainer, let layout = textView.layoutManager else { return }
        let scale = viewScale
        let font = NSFont.systemFont(ofSize: annotation.fontSize, weight: .bold)
        if textView.font != font {
            textView.font = font
            textView.typingAttributes = [.font: font, .foregroundColor: annotation.color.nsColor]
        }
        container.containerSize = CGSize(width: annotation.textWidth ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let lineHeight = layout.defaultLineHeight(for: font)
        // Room for the caret after the last character of an auto-width label.
        let size = CGSize(
            width: annotation.textWidth ?? max(used.width, lineHeight * 0.3) + 2 / scale,
            height: max(used.height, lineHeight)
        )
        let origin = annotation.start.applying(transform)
        textView.frame = CGRect(x: origin.x, y: origin.y, width: size.width * scale, height: size.height * scale)
        textView.setBoundsSize(size)
    }

    func textDidChange(_ notification: Notification) {
        repositionTextView()
        needsDisplay = true
    }

    func textDidEndEditing(_ notification: Notification) {
        MainActor.assumeIsolated { endTextEditing() }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        MainActor.assumeIsolated { endTextEditing() }
        return true
    }

    @MainActor
    private func endTextEditing() {
        guard let textView, let (annotation, isNew) = editing else { return }
        self.textView = nil
        editing = nil
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        textView.delegate = nil
        textView.removeFromSuperview()
        // The typing's undo steps belong to this editor; don't let a later ⌘Z replay them.
        window?.undoManager?.removeAllActions()

        if isNew {
            if !text.isEmpty {
                var created = annotation
                created.text = text
                model.addAnnotation(created)
            }
        } else if text.isEmpty {
            model.removeAnnotation(annotation.id)
        } else if text != annotation.text {
            model.updateAnnotation(annotation.id, checkpoint: true) { $0.text = text }
        }
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
}
