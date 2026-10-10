// Renders site/editor.png: the real Loupe editor (offscreen, dark mode) editing
// a capture of loupe.pics with markup and a gradient background.
// Built and run by scripts/make-screenshot.sh.
import AppKit
import SwiftUI
import WebKit

@main
enum MakeScreenshot {
    @MainActor
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "site/editor.png")

        let page = try await capturePage(URL(string: "https://loupe.pics")!, size: CGSize(width: 1000, height: 860))
        let image = try await makeEditorImage(capture: page)
        try image.representation(using: .png, properties: [:])!.write(to: output)
        print("Wrote \(output.path) (\(image.pixelsWide)×\(image.pixelsHigh))")
    }

    struct PageCapture {
        let image: CGImage
        /// Element rects in CSS points, keyed by name.
        let rects: [String: CGRect]
        /// Page width in CSS points.
        let width: CGFloat
    }

    // MARK: - The page being "screenshotted"

    @MainActor
    static func capturePage(_ url: URL, size: CGSize) async throws -> PageCapture {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size))
        webView.appearance = NSAppearance(named: .aqua)
        window.contentView = webView
        window.orderFront(nil)
        webView.load(URLRequest(url: url))
        while webView.isLoading { await pause(0.1) }
        await pause(1.0) // Fonts and the icon.

        let script = """
        JSON.stringify(Object.fromEntries([
          ['download', '.download'], ['tagline', '.tagline'], ['features', 'h2'], ['firstFeature', '.features li'], ['meta', '.meta']
        ].map(([k, s]) => { const r = document.querySelector(s).getBoundingClientRect(); return [k, [r.x, r.y, r.width, r.height]]; })))
        """
        let json = try await webView.evaluateJavaScript(script) as! String
        let raw = try JSONDecoder().decode([String: [Double]].self, from: Data(json.utf8))
        let rects = raw.mapValues { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }

        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(size.width)) // points; pixels depend on the display
        let snapshot = try await webView.takeSnapshot(configuration: config)
        window.orderOut(nil)
        return PageCapture(image: snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil)!, rects: rects, width: size.width)
    }

    // MARK: - Editor

    @MainActor
    static func makeEditorImage(capture: PageCapture) async throws -> NSBitmapImageRep {
        let pixelsPerPoint = CGFloat(capture.image.width) / capture.width
        let screenshot = Screenshot(image: capture.image, scale: pixelsPerPoint)
        let model = EditorModel(screenshot: screenshot)
        let px: (CGFloat) -> CGFloat = { $0 * pixelsPerPoint } // CSS points → capture pixels
        let red = RGBAColor(hex: 0xFF3B30)

        let download = capture.rects["download"]!
        let tagline = capture.rects["tagline"]!
        let feature = capture.rects["firstFeature"]!
        let features = capture.rects["features"]!
        let meta = capture.rects["meta"]!

        // Colour/size changes apply to the selected annotation, so deselect before each change.
        func style(_ color: RGBAColor, size: Double) {
            model.selectedAnnotationID = nil
            model.setAnnotationColor(color, checkpoint: false)
            model.setAnnotationSize(size, checkpoint: false)
        }

        style(RGBAColor(hex: 0xFFCC00), size: 5)
        model.addAnnotation(model.newAnnotation(.highlighter, points: [
            CGPoint(x: px(tagline.minX + 150), y: px(tagline.minY + 13)),
            CGPoint(x: px(tagline.maxX - 150), y: px(tagline.minY + 13)),
        ]))

        style(red, size: 4)
        var label = model.newAnnotation(.text, points: [CGPoint(x: px(download.maxX + 110), y: px(download.minY - 58))])
        label.text = "One click!"
        model.addAnnotation(label)
        model.addAnnotation(model.newAnnotation(.arrow, points: [
            CGPoint(x: px(download.maxX + 140), y: px(download.minY - 14)),
            CGPoint(x: px(download.maxX + 14), y: px(download.midY)),
        ]))
        model.addAnnotation(model.newAnnotation(.rectangle, points: [
            CGPoint(x: px(feature.minX - 10), y: px(feature.minY - 8)),
            CGPoint(x: px(feature.maxX + 10), y: px(feature.maxY + 8)),
        ]))
        model.addAnnotation(model.newAnnotation(.pixelate, points: [
            CGPoint(x: px(meta.minX + 40), y: px(meta.minY - 3)),
            CGPoint(x: px(meta.maxX - 40), y: px(meta.maxY + 3)),
        ]))
        style(RGBAColor(hex: 0x007AFF), size: 4)
        model.addAnnotation(model.newAnnotation(.step, points: [CGPoint(x: px(download.minX - 34), y: px(download.midY))]))
        model.addAnnotation(model.newAnnotation(.step, points: [CGPoint(x: px(features.minX - 30), y: px(features.midY))]))

        model.state.backdrop.enabled = true
        model.state.backdrop.fill = .gradient(id: "sky")
        model.state.backdrop.padding = 48
        model.state.backdrop.cornerRadius = 12
        model.tool = .arrow
        // Show the arrow selected, with its handles.
        model.selectedAnnotationID = model.state.annotations.first { $0.kind == .arrow }?.id

        let contentSize = CGSize(width: 1280, height: 820)
        let window = EditorWindow(model: model)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.setContentSize(contentSize)
        window.alphaValue = 0
        window.orderFront(nil)
        // Let the preview render (it's delivered on the main queue) and SwiftUI lay out.
        await pause(3)
        window.contentView?.layoutSubtreeIfNeeded()
        await pause(0.5)

        let view = window.contentView!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        window.orderOut(nil)
        return frame(content: rep, size: contentSize, title: "Loupe 2026-10-10 at 09.41.27.png", appearance: window.effectiveAppearance)
    }

    /// Wraps the rendered content in a macOS-style window: title bar, traffic lights, rounded corners, shadow.
    @MainActor
    static func frame(content: NSBitmapImageRep, size: CGSize, title: String, appearance: NSAppearance) -> NSBitmapImageRep {
        let scale = CGFloat(content.pixelsWide) / size.width
        let titleBar: CGFloat = 32
        let margin: CGFloat = 60
        let windowRect = CGRect(x: margin, y: margin, width: size.width, height: size.height + titleBar)
        let canvas = CGSize(width: windowRect.width + margin * 2, height: windowRect.height + margin * 2)

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let context = NSGraphicsContext.current!.cgContext

        var background = NSColor.windowBackgroundColor
        var titleColor = NSColor.secondaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
            titleColor = NSColor.secondaryLabelColor.usingColorSpace(.sRGB)!
        }

        let shape = CGPath(roundedRect: windowRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: CGColor(gray: 0, alpha: 0.45))
        context.addPath(shape)
        context.setFillColor(background.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        background.setFill()
        windowRect.fill()
        // Title bar.
        NSColor(white: 0.17, alpha: 1).setFill()
        CGRect(x: windowRect.minX, y: windowRect.maxY - titleBar, width: windowRect.width, height: titleBar).fill()
        NSColor(white: 0, alpha: 0.5).setFill()
        CGRect(x: windowRect.minX, y: windowRect.maxY - titleBar - 1, width: windowRect.width, height: 1).fill()
        for (index, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            RGBAColor(hex: UInt32(hex)).nsColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: windowRect.minX + 14 + CGFloat(index) * 20, y: windowRect.maxY - titleBar / 2 - 6, width: 12, height: 12)).fill()
        }
        let titleText = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: titleColor,
        ])
        let titleSize = titleText.size()
        titleText.draw(at: CGPoint(x: windowRect.midX - titleSize.width / 2, y: windowRect.maxY - titleBar / 2 - titleSize.height / 2))
        // Content.
        content.draw(in: CGRect(x: windowRect.minX, y: windowRect.minY, width: size.width, height: size.height))
        context.restoreGState()

        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        context.setLineWidth(1)
        context.strokePath()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @MainActor
    static func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
