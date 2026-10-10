// Renders site/editor.png: the real Loupe editor (offscreen, dark mode) editing
// a painted mountain-lake landscape with markup and a gradient background.
// Built and run by scripts/make-screenshot.sh.
import AppKit
import SwiftUI

@main
enum MakeScreenshot {
    @MainActor
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "site/editor.png")

        let scene = paintLandscape(size: CGSize(width: 1000, height: 700), scale: 2)
        let image = try await makeEditorImage(capture: scene)
        try image.representation(using: .png, properties: [:])!.write(to: output)
        print("Wrote \(output.path) (\(image.pixelsWide)×\(image.pixelsHigh))")
    }

    struct Landscape {
        let image: CGImage
        /// Pixels per point.
        let scale: CGFloat
        /// Landmarks in points, top-left origin, keyed by name.
        let points: [String: CGPoint]
    }

    // MARK: - The photo being "screenshotted"

    /// Deterministic RNG so the painting is the same on every run.
    struct Seeded {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 33) / CGFloat(1 << 31)
        }
    }

    /// A ridge line by midpoint displacement: `count` heights (0…1) across the width.
    static func ridge(_ rng: inout Seeded, count: Int = 257, roughness: CGFloat) -> [CGFloat] {
        var h = [CGFloat](repeating: 0, count: count)
        h[0] = rng.next(); h[count - 1] = rng.next()
        var step = count - 1, amplitude: CGFloat = 0.5
        while step > 1 {
            let half = step / 2
            for i in stride(from: half, to: count, by: step) {
                h[i] = (h[i - half] + h[i + half]) / 2 + (rng.next() - 0.5) * amplitude
            }
            step = half
            amplitude *= roughness
        }
        return h
    }

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Paints a mountain lake at dusk: stars, a low sun, hazy ridges, pines, a cabin and the reflection.
    static func paintLandscape(size: CGSize, scale: CGFloat) -> Landscape {
        let width = size.width, height = size.height
        let shore: CGFloat = 470 // Water line, from the top.
        var rng = Seeded(state: 0x10_0be)
        let context = CGContext(
            data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Work in points with a top-left origin.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
            CGGradient(colorsSpace: space, colors: stops.map { color($0.0) } as CFArray, locations: stops.map(\.1))!
        }

        // Sky.
        context.drawLinearGradient(
            gradient([(0x141A3F, 0), (0x3B2A68, 0.35), (0x9A4A7E, 0.68), (0xF0896A, 0.9), (0xFFC58A, 1)]),
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: shore), options: [.drawsAfterEndLocation]
        )
        // Stars, fading toward the horizon.
        for _ in 0..<260 {
            let x = rng.next() * width, y = pow(rng.next(), 1.6) * shore * 0.6
            let r = 0.4 + rng.next() * 0.9
            context.setFillColor(CGColor(gray: 1, alpha: (0.25 + rng.next() * 0.7) * (1 - y / (shore * 0.6))))
            context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        // Sun and glow.
        let sun = CGPoint(x: 700, y: 262)
        context.drawRadialGradient(
            CGGradient(colorsSpace: space, colors: [color(0xFFD9A0, 0.75), color(0xFF9A6A, 0.25), color(0xFF7A6A, 0)] as CFArray, locations: [0, 0.3, 1])!,
            startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 300, options: []
        )
        context.setFillColor(color(0xFFE8BE))
        context.fillEllipse(in: CGRect(x: sun.x - 44, y: sun.y - 44, width: 88, height: 88))

        // Ridges, far to near: (base, height, roughness, colour). Far ones take on the sky's haze.
        let layers: [(CGFloat, CGFloat, CGFloat, UInt32)] = [
            (400, 150, 0.55, 0xB86A8C), (430, 210, 0.52, 0x7A4677), (455, 150, 0.5, 0x48305E), (472, 90, 0.48, 0x241B3D),
        ]
        var summit = CGPoint.zero
        for (index, layer) in layers.enumerated() {
            var h = ridge(&rng, roughness: layer.2)
            if index == 1 { // The tall one: a clear summit left of centre.
                for i in h.indices {
                    let d = (CGFloat(i) / CGFloat(h.count - 1) - 0.3) / 0.11
                    h[i] += 0.75 * exp(-d * d)
                }
            }
            let lo = h.min()!, hi = h.max()!
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: height))
            for (i, value) in h.enumerated() {
                let point = CGPoint(x: CGFloat(i) / CGFloat(h.count - 1) * width, y: layer.0 - (value - lo) / (hi - lo) * layer.1)
                path.addLine(to: point)
                if index == 1, point.y < (summit == .zero ? .infinity : summit.y) { summit = point }
            }
            path.addLine(to: CGPoint(x: width, y: height))
            path.closeSubpath()
            context.saveGState()
            context.addPath(path)
            context.clip()
            let top = layer.0 - layer.1
            context.drawLinearGradient(
                CGGradient(colorsSpace: space, colors: [color(layer.3), color(layer.3, 1).copy(alpha: 1)!, color(0x120E24)] as CFArray, locations: [0, 0.4, 1])!,
                start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: height + 200 - CGFloat(index) * 40), options: []
            )
            // Snow on the tall one's summit.
            if index == 1 {
                let snow = CGMutablePath()
                snow.move(to: CGPoint(x: summit.x - 90, y: summit.y - 10))
                for i in 0...8 {
                    let x = summit.x - 90 + CGFloat(i) * 22.5
                    snow.addLine(to: CGPoint(x: x, y: summit.y + 22 + (i % 2 == 0 ? 10 : -4) - abs(x - summit.x) * 0.12))
                }
                snow.addLine(to: CGPoint(x: summit.x + 90, y: summit.y - 10))
                context.addPath(snow)
                context.setFillColor(CGColor(gray: 1, alpha: 0.75))
                context.fillPath()
            }
            context.restoreGState()
        }

        // Pines along both shores.
        func pine(_ x: CGFloat, _ base: CGFloat, _ h: CGFloat) {
            let w = h * 0.32
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: base - h))
            for tier in 1...4 {
                let y = base - h + h * CGFloat(tier) / 4.4
                let spread = w * (0.35 + 0.65 * CGFloat(tier) / 4)
                path.addLine(to: CGPoint(x: x + spread, y: y))
                path.addLine(to: CGPoint(x: x + spread * 0.45, y: y - h * 0.04))
            }
            for tier in (1...4).reversed() {
                let y = base - h + h * CGFloat(tier) / 4.4
                let spread = w * (0.35 + 0.65 * CGFloat(tier) / 4)
                path.addLine(to: CGPoint(x: x - spread * 0.45, y: y - h * 0.04))
                path.addLine(to: CGPoint(x: x - spread, y: y))
            }
            path.closeSubpath()
            context.addPath(path)
            context.addRect(CGRect(x: x - w * 0.06, y: base - h * 0.12, width: w * 0.12, height: h * 0.12))
            context.setFillColor(color(0x0C0A18))
            context.fillPath()
        }
        // Low banks the trees stand on.
        context.setFillColor(color(0x0C0A18))
        context.fill(CGRect(x: 0, y: shore - 6, width: 300, height: 8))
        context.fill(CGRect(x: 760, y: shore - 4, width: 240, height: 6))
        var x: CGFloat = -10
        while x < 290 { pine(x, shore, 70 + rng.next() * 110 - x * 0.18); x += 14 + rng.next() * 16 }
        x = 800
        while x < 1010 { pine(x, shore, 50 + rng.next() * 80 + (x - 800) * 0.35); x += 13 + rng.next() * 15 }

        // A cabin with a lit window, on the right bank.
        let cabin = CGRect(x: 700, y: shore - 30, width: 46, height: 28)
        context.setFillColor(color(0x0C0A18))
        context.fill(cabin)
        context.move(to: CGPoint(x: cabin.minX - 6, y: cabin.minY))
        context.addLine(to: CGPoint(x: cabin.midX, y: cabin.minY - 20))
        context.addLine(to: CGPoint(x: cabin.maxX + 6, y: cabin.minY))
        context.fillPath()
        context.fill(CGRect(x: cabin.maxX - 14, y: cabin.minY - 22, width: 6, height: 14)) // Chimney.
        let window = CGRect(x: cabin.minX + 10, y: cabin.minY + 9, width: 11, height: 10)
        context.drawRadialGradient(
            CGGradient(colorsSpace: space, colors: [color(0xFFC46A, 0.55), color(0xFFC46A, 0)] as CFArray, locations: [0, 1])!,
            startCenter: CGPoint(x: window.midX, y: window.midY), startRadius: 0, endCenter: CGPoint(x: window.midX, y: window.midY), endRadius: 30, options: []
        )
        context.setFillColor(color(0xFFD27A))
        context.fill(window)

        // The lake: the scene above, mirrored, darkened, with ripples.
        let above = context.makeImage()!.cropping(to: CGRect(x: 0, y: 0, width: width * scale, height: shore * scale))!
        context.saveGState()
        context.translateBy(x: 0, y: shore * 2)
        context.scaleBy(x: 1, y: -1)
        // CGContext draws images upright in its own (flipped here) space, so this lands mirrored below the shore.
        context.translateBy(x: 0, y: shore)
        context.scaleBy(x: 1, y: -1)
        context.draw(above, in: CGRect(x: 0, y: 0, width: width, height: shore))
        context.restoreGState()
        context.drawLinearGradient(
            CGGradient(colorsSpace: space, colors: [color(0x1A1433, 0.35), color(0x0A0818, 0.85)] as CFArray, locations: [0, 1])!,
            start: CGPoint(x: 0, y: shore), end: CGPoint(x: 0, y: height), options: []
        )
        for _ in 0..<140 {
            let y = shore + 4 + pow(rng.next(), 1.4) * (height - shore)
            let length = 20 + rng.next() * 140 * (y - shore) / (height - shore)
            let cx = rng.next() < 0.45 ? sun.x + (rng.next() - 0.5) * 110 : rng.next() * width
            let nearSun = abs(cx - sun.x) < 70
            context.setFillColor(nearSun ? color(0xFFD9A0, 0.5) : CGColor(gray: 1, alpha: 0.07))
            context.fill(CGRect(x: cx - length / 2, y: y, width: length, height: 0.8 + (y - shore) / 160))
        }

        return Landscape(image: context.makeImage()!, scale: scale, points: [
            "summit": summit, "cabin": CGPoint(x: cabin.midX, y: cabin.midY - 6),
        ])
    }

    // MARK: - Editor

    @MainActor
    static func makeEditorImage(capture: Landscape) async throws -> NSBitmapImageRep {
        let screenshot = Screenshot(image: capture.image, scale: capture.scale)
        let model = EditorModel(screenshot: screenshot)
        let px: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * capture.scale, y: $0.y * capture.scale) } // points → capture pixels
        let red = RGBAColor(hex: 0xFF3B30)

        let summit = capture.points["summit"]!
        let cabin = capture.points["cabin"]!

        // Colour/size changes apply to the selected annotation, so deselect before each change.
        func style(_ color: RGBAColor, size: Double) {
            model.selectedAnnotationID = nil
            model.setAnnotationColor(color, checkpoint: false)
            model.setAnnotationSize(size, checkpoint: false)
        }

        style(RGBAColor(hex: 0xFFFFFF), size: 4)
        var label = model.newAnnotation(.text, points: [px(CGPoint(x: summit.x + 120, y: summit.y - 40))])
        label.text = "We’re going up there"
        model.addAnnotation(label)
        style(red, size: 4)
        model.addAnnotation(model.newAnnotation(.arrow, points: [
            px(CGPoint(x: summit.x + 150, y: summit.y + 4)),
            px(CGPoint(x: summit.x + 16, y: summit.y + 6)),
        ]))
        model.addAnnotation(model.newAnnotation(.ellipse, points: [
            px(CGPoint(x: cabin.x - 50, y: cabin.y - 42)), px(CGPoint(x: cabin.x + 50, y: cabin.y + 34)),
        ]))
        style(RGBAColor(hex: 0x007AFF), size: 4)
        model.addAnnotation(model.newAnnotation(.step, points: [px(CGPoint(x: cabin.x - 66, y: cabin.y - 40))]))
        model.addAnnotation(model.newAnnotation(.step, points: [px(CGPoint(x: summit.x - 40, y: summit.y - 34))]))

        model.state.backdrop.enabled = true
        model.state.backdrop.fill = .gradient(id: "dusk")
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
