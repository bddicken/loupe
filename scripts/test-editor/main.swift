// Checks the editor's mouse behaviour by driving the real editor UI (the same views
// the app shows) with synthetic mouse events, in a window that's never visible:
// selecting, moving and resizing shapes with each tool, drawing on top of other
// shapes, the cursor, and the toolbar while zoomed in.
// Built and run by scripts/test-editor.sh. Pass -v to list every check.
import AppKit
import SwiftUI

/// Never shown, and never moved or shrunk to fit the screen, so the layout the
/// checks rely on is the same on every Mac.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@main
@MainActor
enum TestEditor {
    static var passed = 0
    static var failed = 0
    static var eventNumber = 0
    static let verbose = CommandLine.arguments.contains("-v")

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failed += 1 }
        guard verbose || !ok else { return }
        let detail = detail()
        print("\(ok ? "pass" : "FAIL")  \(name)\(detail.isEmpty || ok ? "" : "  (\(detail))")")
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let view = view as? T { return view }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    // MARK: - Synthetic input (window coordinates)

    static var window: NSWindow!

    static func send(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        eventNumber += 1
        window.sendEvent(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1
        )!)
    }

    /// Press, drag through a few steps, release.
    static func drag(_ a: CGPoint, _ b: CGPoint, flags: NSEvent.ModifierFlags = []) async {
        send(.leftMouseDown, a, flags: flags)
        for step in 1...6 {
            let t = CGFloat(step) / 6
            send(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: flags)
        }
        send(.leftMouseUp, b, flags: flags)
        await pause(0.15)
    }

    static func click(_ point: CGPoint, clicks: Int = 1) async {
        send(.leftMouseDown, point, clicks: clicks)
        send(.leftMouseUp, point, clicks: clicks)
        await pause(0.15)
    }

    /// Lets SwiftUI lay out after a change that moves things (zoom, a panel).
    static func settle() async {
        await pause(0.6)
        window.contentView?.layoutSubtreeIfNeeded()
        await pause(0.3)
    }

    // MARK: - The checks

    static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)

        // A plain 1000×700pt Retina "screenshot", which the window below shows at 100%:
        // image points are view points, and source pixels twice that.
        let size = CGSize(width: 1000, height: 700)
        let context = CGContext(
            data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
        let model = EditorModel(screenshot: Screenshot(image: context.makeImage()!, scale: 2))

        let window = OffscreenWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false
        )
        Self.window = window
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: EditorView(model: model))
        window.contentView = content
        window.setContentSize(CGSize(width: 1400, height: 900))
        // In the window list (so events reach its views) but invisible, and out of the pointer's way.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFront(nil)
        // The first preview render is delivered on the main queue.
        await pause(2)
        await settle()

        guard let canvas = find(AnnotationCanvasView.self, in: content) else {
            print("FAIL  the editor has no annotation canvas")
            exit(1)
        }
        // The canvas has a 16pt margin around the image for handles on its edges.
        let margin: CGFloat = 16
        guard abs(canvas.bounds.width - (size.width + margin * 2)) < 1 else {
            print("FAIL  the image isn't shown at 100% (canvas is \(canvas.bounds.size)); the checks' coordinates assume it is")
            exit(1)
        }
        /// Image points → canvas view points.
        func v(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + margin, y: y + margin) }
        /// Image points → window points.
        func c(_ x: CGFloat, _ y: CGFloat) -> CGPoint { canvas.convert(v(x, y), to: nil) }
        /// A toolbar tool button, in window points: the toolbar starts at the editor's
        /// top-left with 10pt of padding; its buttons are 30×26, 2pt apart, in tool order.
        func toolPoint(_ tool: AnnotationTool) -> CGPoint {
            let index = CGFloat(AnnotationTool.allCases.firstIndex(of: tool)!)
            return content.convert(CGPoint(x: 10 + 15 + index * 32, y: 6 + 13), to: nil)
        }
        func pick(_ tool: AnnotationTool) async {
            await click(toolPoint(tool))
            check("toolbar click picks \(tool.title)", model.tool == tool, "tool is \(model.tool)")
        }
        func annotation(_ id: UUID) -> Annotation? { model.state.annotations.first { $0.id == id } }
        var count: Int { model.state.annotations.count }
        var selectedKind: String { model.selectedAnnotation.map { "\($0.kind)" } ?? "nothing" }
        /// Pixels → image points.
        func points(_ rect: CGRect) -> CGRect { rect.applying(CGAffineTransform(scaleX: 0.5, y: 0.5)) }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

        // --- Two pixelations; click the earlier one to select it, then resize and move it
        await pick(.pixelate)
        await drag(c(100, 100), c(260, 200))
        await drag(c(400, 300), c(560, 420))
        check("two pixelations drawn", count == 2, "\(count) shapes")
        guard count == 2 else { exit(1) }
        let a = model.state.annotations[0], b = model.state.annotations[1]
        check("the one just drawn is selected", model.selectedAnnotationID == b.id)

        let untouched = model.state
        await click(c(180, 150))
        check("click inside an earlier pixelation selects it (Pixelate tool)", model.selectedAnnotationID == a.id, "selected \(selectedKind)")
        check("  …without changing anything", model.state == untouched)
        await drag(c(260, 200), c(300, 240))
        var box = points(annotation(a.id)!.rect)
        check("dragging its corner resizes it", near(box.width, 200) && near(box.height, 140) && count == 2, "\(box), \(count) shapes")
        await drag(c(300, 170), c(340, 170))
        box = points(annotation(a.id)!.rect)
        check("dragging its right side's handle moves that side only", near(box.width, 240) && near(box.height, 140) && near(box.minX, 100) && near(box.minY, 100) && count == 2, "\(box), \(count) shapes")
        await drag(c(220, 100), c(220, 80))
        box = points(annotation(a.id)!.rect)
        check("dragging its top side's handle moves that side only", near(box.width, 240) && near(box.height, 160) && near(box.minX, 100) && near(box.maxY, 240) && count == 2, "\(box), \(count) shapes")
        await drag(c(180, 150), c(200, 180))
        let moved = points(annotation(a.id)!.rect)
        check("dragging inside the selected pixelation moves it", near(moved.minX, box.minX + 20) && near(moved.minY, box.minY + 30) && near(moved.width, box.width) && count == 2, "\(box) → \(moved), \(count) shapes")
        await click(c(480, 360))
        check("click inside the other pixelation selects it", model.selectedAnnotationID == b.id, "selected \(selectedKind)")
        await click(c(800, 600))
        check("click on empty image deselects", model.selectedAnnotationID == nil && count == 2)

        // --- Dragging over an unselected shape draws; clicks pick the shape under them
        var n = count
        await drag(c(420, 320), c(470, 360))
        check("drag inside an unselected pixelation draws a new one", count == n + 1 && annotation(b.id)!.rect == b.rect, "\(n) → \(count) shapes")
        let small = model.state.annotations.last!
        await click(c(480, 400)) // Inside b, outside the small one.
        check("click selects the big pixelation under it", model.selectedAnnotationID == b.id, "selected \(selectedKind)")
        await click(c(445, 340))
        check("click on a smaller shape lying on the selected one selects that", model.selectedAnnotationID == small.id)
        await pick(.pixelate)
        check("picking the current tool again deselects", model.selectedAnnotationID == nil)

        // --- Switch tools right after each shape, starting each on or next to an earlier one
        for (tool, from, to) in [
            (AnnotationTool.blur, c(600, 100), c(760, 220)),
            (.rectangle, c(620, 120), c(740, 200)),
            (.arrow, c(620, 160), c(730, 190)),       // Starts on the rectangle's outline.
            (.ellipse, c(100, 400), c(220, 500)),
            (.redact, c(120, 420), c(200, 480)),      // Starts by the ellipse's outline.
            (.pixelate, c(700, 180), c(800, 300)),    // Starts by the arrow.
            (.line, c(760, 220), c(860, 260)),        // Starts on the blur's corner.
            (.highlighter, c(100, 450), c(220, 450)), // Starts on the ellipse's outline.
        ] {
            await pick(tool)
            let before = model.state.annotations
            await drag(from, to)
            check("  …and a drag draws a \(tool.title), moving nothing", count == before.count + 1 && model.state.annotations.last?.kind == tool.kind
                  && Array(model.state.annotations.prefix(before.count)) == before, "\(before.count) → \(count) shapes")
        }
        let placeholder = model.newAnnotation(.arrow, points: [.zero, .zero])
        let arrow = model.state.annotations.first { $0.kind == .arrow } ?? placeholder
        let ellipse = model.state.annotations.first { $0.kind == .ellipse } ?? placeholder

        // --- A click selects with any drawing tool; the selected shape moves and resizes
        await pick(.rectangle)
        await click(c(675, 175))
        check("Rectangle tool: click on an arrow selects it", model.selectedAnnotationID == arrow.id, "selected \(selectedKind)")
        await drag(c(675, 175), c(685, 215))
        check("  …and dragging the selected arrow moves it", annotation(arrow.id)?.start != arrow.start && model.state.annotations.filter { $0.kind == .rectangle }.count == 1)
        await pick(.arrow)
        await click(c(160, 412))
        check("Arrow tool: click inside a hollow ellipse selects it", model.selectedAnnotationID == ellipse.id, "selected \(selectedKind)")
        n = count
        await drag(c(160, 412), c(300, 560))
        check("  …and dragging inside it draws (a hollow shape is held by its outline)", count == n + 1 && annotation(ellipse.id)?.rect == ellipse.rect)

        await pick(.pixelate)
        await click(c(480, 400))
        check("the big pixelation is selected again", model.selectedAnnotationID == b.id, "selected \(selectedKind)")
        n = count
        await drag(c(500, 380), c(540, 410), flags: .option)
        check("⌥-drag inside the selected pixelation draws", count == n + 1 && annotation(b.id)!.rect == b.rect)

        // A box too small for side handles: its side moves it, like the rest of it.
        await pick(.redact)
        await drag(c(850, 50), c(880, 80))
        let tiny = model.state.annotations.last!
        await drag(c(880, 65), c(900, 65))
        box = points(annotation(tiny.id)!.rect)
        check("a small box has no side handles (dragging its side moves it)", near(box.width, 30) && near(box.height, 30) && near(box.minX, 870), "\(box)")

        // --- Select, Counter and Text tools
        await pick(.step)
        n = count
        await click(c(640, 150)) // Inside the blur and the rectangle.
        check("Counter tool: click inside a blur places a counter", count == n + 1 && model.state.annotations.last?.kind == .step)
        await pick(.select)
        check("the Select tool keeps the selection", model.selectedAnnotationID != nil)
        box = points(annotation(a.id)!.rect)
        await drag(c(box.midX, box.midY), c(box.midX + 30, box.midY + 10))
        check("Select tool: dragging inside an unselected pixelation moves it", model.selectedAnnotationID == a.id && near(points(annotation(a.id)!.rect).minX, box.minX + 30))
        var label = model.newAnnotation(.text, points: [CGPoint(x: 1000, y: 1000)])
        label.text = "Hello there"
        model.addAnnotation(label)
        await pick(.arrow)
        await pause(0.2)
        n = count
        await drag(c(520, 510), c(600, 600))
        check("Arrow tool: a drag starting on a text label draws an arrow", count == n + 1 && annotation(label.id)!.start == label.start, "\(n) → \(count) shapes")
        await pick(.arrow)
        await click(c(560, 513))
        check("Arrow tool: click on a text selects it", model.selectedAnnotationID == label.id, "selected \(selectedKind)")
        await click(c(560, 513), clicks: 2)
        check("Arrow tool: double-click on a text edits it", window.firstResponder is NSTextView)
        model.commitTextEditing?()

        // --- The cursor says what a press would do
        func cursor(_ x: CGFloat, _ y: CGFloat, option: Bool = false) -> NSCursor { canvas.cursor(atViewPoint: v(x, y), option: option) }
        let straight: [NSCursor] = [.arrow, .crosshair, .iBeam, .openHand, .resizeLeftRight, .resizeUpDown]
        func isDiagonal(_ cursor: NSCursor) -> Bool { !straight.contains { $0 === cursor } }
        await pick(.pixelate)
        check("cursor: crosshair over the image with a drawing tool", cursor(900, 650) === NSCursor.crosshair)
        check("cursor: arrow off the image", canvas.cursor(atViewPoint: CGPoint(x: 4, y: 4)) === NSCursor.arrow)
        check("cursor: crosshair over an unselected pixelation (a drag draws)", cursor(480, 400) === NSCursor.crosshair)
        await click(c(480, 400))
        check("cursor: open hand over the selected pixelation", model.selectedAnnotationID == b.id && cursor(480, 400) === NSCursor.openHand)
        check("cursor: crosshair over it with ⌥ (a drag draws)", cursor(480, 400, option: true) === NSCursor.crosshair)
        check("cursor: left-right resize on its right side's handle", cursor(560, 360) === NSCursor.resizeLeftRight)
        check("cursor: up-down resize on its top side's handle", cursor(480, 300) === NSCursor.resizeUpDown)
        if #available(macOS 15, *) {
            check("cursor: diagonal resize on its corners", isDiagonal(cursor(560, 420)) && isDiagonal(cursor(560, 300)) && cursor(560, 420).image !== cursor(560, 300).image)
        }
        await pick(.select)
        box = points(annotation(a.id)!.rect)
        check("cursor: Select tool, open hand over a shape and arrow elsewhere", cursor(box.midX, box.midY) === NSCursor.openHand && cursor(900, 650) === NSCursor.arrow)
        model.selectedAnnotationID = arrow.id
        if let tip = annotation(arrow.id)?.end {
            check("cursor: resize along a nearly level arrow on its tip", cursor(tip.x / 2, tip.y / 2) === NSCursor.resizeLeftRight)
        }
        await pick(.text)
        check("cursor: Text tool, I-beam over the image and over a text", cursor(900, 650) === NSCursor.iBeam && cursor(560, 513) === NSCursor.iBeam)
        check("cursor: Text tool, open hand on another shape's outline", cursor(620, 135) === NSCursor.openHand)

        // --- Zoomed in, the image reaches under the toolbar and panels; they must keep working
        model.selectedAnnotationID = nil
        model.zoom(by: 4)
        await settle()
        n = count
        for tool in [AnnotationTool.rectangle, .blur, .select, .arrow] {
            await click(toolPoint(tool))
            check("zoomed in: toolbar click picks \(tool.title)", model.tool == tool, "tool is \(model.tool)")
        }
        check("zoomed in: toolbar clicks drew nothing", count == n)
        // Scrolling pans the image only over the canvas area, not over the sidebar.
        if let gestures = canvas.window?.contentView?.firstDescendant(named: "CanvasGestureView") {
            let overSidebar = gestures.convert(CGPoint(x: 1300, y: 500), from: nil)
            check("zoomed in: the canvas's scroll area stops at the sidebar", !gestures.visibleRect.contains(overSidebar))
        }
        model.showsBackgroundPanel = true
        await settle()
        // The panel's close button, at its top right (the panel is 260pt wide).
        await click(content.convert(CGPoint(x: 233, y: 23), to: nil))
        check("zoomed in: the background panel's close button works", !model.showsBackgroundPanel)
        check("  …and drew nothing", count == n)
        model.showsBackgroundPanel = false
        await settle()
        await pick(.rectangle)
        await drag(CGPoint(x: 500, y: 400), CGPoint(x: 620, y: 480))
        check("zoomed in: dragging on the visible canvas draws", count == n + 1 && model.state.annotations.last?.kind == .rectangle)

        window.orderOut(nil)
        print(failed == 0 ? "Editor checks: all \(passed) passed" : "Editor checks: \(failed) of \(passed + failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}

extension NSView {
    /// For views whose types are private to the app.
    func firstDescendant(named name: String) -> NSView? {
        if String(describing: type(of: self)) == name { return self }
        return subviews.lazy.compactMap { $0.firstDescendant(named: name) }.first
    }
}
