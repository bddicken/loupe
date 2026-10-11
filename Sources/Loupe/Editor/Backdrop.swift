import AppKit
import ImageIO
import SwiftUI

/// An sRGB color that can live in EditState (Equatable) and UserDefaults (Codable).
struct RGBAColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// A background preset: a linear or radial gradient, optionally with a texture.
/// `draw(in:rect:pixelsPerPoint:)` is the single renderer used by export, the
/// live editor background and the swatches, so all three always match.
struct GradientPreset: Identifiable {
    enum Style { case linear, radial }

    enum Texture {
        case none
        /// Film grain, blended over the gradient.
        case grain(opacity: Double)
        /// A grid of dots; sizes in points.
        case dots(RGBAColor, spacing: Double, radius: Double)
        /// Thin grid lines, like a blueprint.
        case grid(RGBAColor, spacing: Double)
        /// Diagonal pinstripes.
        case lines(RGBAColor, spacing: Double, width: Double)
        /// A fine woven crosshatch, like linen.
        case crosshatch(RGBAColor, spacing: Double)
        /// Scattered stone chips, like terrazzo.
        case flecks([RGBAColor], spacing: Double)
        /// Wavy contour lines, like a topographic map.
        case contours(RGBAColor, spacing: Double, amplitude: Double)
        /// Dots that grow across the canvas, like a halftone print.
        case halftone(RGBAColor, spacing: Double, maxRadius: Double)
        /// An isometric (triangle) grid.
        case isometric(RGBAColor, spacing: Double)
    }

    enum Category: String, CaseIterable, Identifiable {
        case neutral = "Neutral", light = "Light", dark = "Dark", colorful = "Colorful", textured = "Textured"
        var id: String { rawValue }
    }

    let id: String
    let category: Category
    let colors: [RGBAColor]
    /// Direction in degrees, y-up: 0 = left→right, -45 = top-left→bottom-right.
    let angle: Double
    let style: Style
    let texture: Texture
    /// Film grain layered on top of any texture (0 = none).
    let grain: Double

    init(_ id: String, _ category: Category, _ hexes: [UInt32], angle: Double = -45, style: Style = .linear,
         texture: Texture = .none, grain: Double = 0) {
        self.id = id
        self.category = category
        colors = hexes.map(RGBAColor.init(hex:))
        self.angle = angle
        self.style = style
        self.texture = texture
        self.grain = grain
    }

    var name: String { id.prefix(1).uppercased() + id.dropFirst() }

    static let all: [GradientPreset] = [
        // Neutral
        GradientPreset("fog", .neutral, [0xF4F4F6, 0xD9DADF]),
        GradientPreset("stone", .neutral, [0xDDD7CF, 0xB8B0A5]),
        GradientPreset("slate", .neutral, [0x95A1B5, 0x5E697E]),
        GradientPreset("concrete", .neutral, [0xBDBDBD, 0x8E8E8E], texture: .grain(opacity: 0.35)),
        GradientPreset("sand", .neutral, [0xEDE7DB, 0xCFC5B2]),
        GradientPreset("pewter", .neutral, [0xB4B8BF, 0x7C818B], style: .radial),
        // Light
        GradientPreset("cream", .light, [0xFDFCFB, 0xE2D1C3]),
        GradientPreset("peach", .light, [0xFFDEE9, 0xB5FFFC]),
        GradientPreset("blush", .light, [0xFDE8EF, 0xEBDDFB]),
        GradientPreset("mist", .light, [0xE3F6FA, 0xE6E9F7]),
        GradientPreset("butter", .light, [0xFFF6D6, 0xFFE3B3], style: .radial),
        GradientPreset("lilac", .light, [0xF5F0FF, 0xE1D7FA]),
        GradientPreset("seafoam", .light, [0xEAFBF5, 0xCDEFE6], angle: -90),
        // Dark
        GradientPreset("midnight", .dark, [0x232526, 0x414345]),
        GradientPreset("graphite", .dark, [0x434343, 0x000000]),
        GradientPreset("dusk", .dark, [0x2C3E50, 0xFD746C]),
        GradientPreset("obsidian", .dark, [0x2D3039, 0x0A0B0E], style: .radial),
        GradientPreset("deepsea", .dark, [0x0F2027, 0x203A43, 0x2C5364]),
        GradientPreset("nightfall", .dark, [0x141E30, 0x243B55], angle: -90),
        GradientPreset("ember", .dark, [0x5C2A16, 0x2A140C, 0x120807], style: .radial),
        GradientPreset("abyss", .dark, [0x0B132B, 0x1C2541, 0x3A506B], angle: -60),
        // Colorful
        GradientPreset("sky", .colorful, [0x56CCF2, 0x2F80ED]),
        GradientPreset("ocean", .colorful, [0x2E3192, 0x1BFFFF]),
        GradientPreset("violet", .colorful, [0x8E2DE2, 0x4A00E0]),
        GradientPreset("berry", .colorful, [0xFC466B, 0x3F5EFB]),
        GradientPreset("candy", .colorful, [0xF857A6, 0xFF5858]),
        GradientPreset("sunset", .colorful, [0xFF7E5F, 0xFEB47B]),
        GradientPreset("citrus", .colorful, [0xF7971E, 0xFFD200]),
        GradientPreset("mint", .colorful, [0x00B09B, 0x96C93D]),
        GradientPreset("aurora", .colorful, [0x00C9FF, 0x92FE9D]),
        GradientPreset("lagoon", .colorful, [0x00DBDE, 0x6A5BFF, 0xFC00FF]),
        GradientPreset("tropic", .colorful, [0xF9D423, 0xFF7A3D, 0xE8317A], angle: -30),
        GradientPreset("neon", .colorful, [0xFF2DB4, 0x5B2BD8, 0x1B1464], style: .radial),
        GradientPreset("flamingo", .colorful, [0xFF9A8B, 0xFF6A88, 0xFF99AC]),
        GradientPreset("lime", .colorful, [0xD4FC79, 0x56AB2F], angle: -60),
        // Textured
        GradientPreset("paper", .textured, [0xFBF8F1, 0xEFE8DA], texture: .grain(opacity: 0.45)),
        GradientPreset("grainy dusk", .textured, [0x3A1C71, 0xD76D77, 0xFFAF7B], texture: .grain(opacity: 0.5)),
        GradientPreset("blueprint", .textured, [0x1F4A9C, 0x14316B], style: .radial,
                       texture: .grid(RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.14), spacing: 24)),
        GradientPreset("polka", .textured, [0xFFE6E1, 0xFFD3DA],
                       texture: .dots(RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.75), spacing: 18, radius: 3)),
        GradientPreset("carbon", .textured, [0x2A2A2D, 0x141416],
                       texture: .lines(RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.06), spacing: 7, width: 2)),
        GradientPreset("graph", .textured, [0xFAFAF7, 0xF0F0EA],
                       texture: .grid(RGBAColor(red: 0.2, green: 0.45, blue: 0.85, alpha: 0.13), spacing: 16)),
        GradientPreset("linen", .textured, [0xF4EEE3, 0xE5DACA],
                       texture: .crosshatch(RGBAColor(red: 0.45, green: 0.35, blue: 0.22, alpha: 0.07), spacing: 3), grain: 0.25),
        GradientPreset("terrazzo", .textured, [0xF8F4EF, 0xEEE8E0],
                       texture: .flecks([
                           RGBAColor(hex: 0xD9745B), RGBAColor(hex: 0x8FA88B), RGBAColor(hex: 0x6C7A89),
                           RGBAColor(hex: 0xE3B45B), RGBAColor(hex: 0xB9A99A),
                       ], spacing: 16)),
        GradientPreset("topo", .textured, [0x1F2B3A, 0x0F1720], style: .radial,
                       texture: .contours(RGBAColor(red: 0.6, green: 0.85, blue: 1, alpha: 0.13), spacing: 13, amplitude: 7)),
        GradientPreset("halftone", .textured, [0xFF7A6B, 0xC2416B],
                       texture: .halftone(RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.28), spacing: 12, maxRadius: 4.2)),
        GradientPreset("isometric", .textured, [0xEFF3F8, 0xDCE3ED],
                       texture: .isometric(RGBAColor(red: 0.25, green: 0.35, blue: 0.5, alpha: 0.1), spacing: 26)),
        GradientPreset("velvet", .textured, [0x5B2E7A, 0x2A0A3D], style: .radial, grain: 0.55),
        GradientPreset("chalkboard", .textured, [0x34453B, 0x222E28], grain: 0.45),
        GradientPreset("dot grid", .textured, [0x1B2333, 0x0E131D],
                       texture: .dots(RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.22), spacing: 14, radius: 1.3)),
        GradientPreset("sandstone", .textured, [0xE8CBA8, 0xC99A72],
                       texture: .contours(RGBAColor(red: 0.45, green: 0.25, blue: 0.1, alpha: 0.1), spacing: 11, amplitude: 4), grain: 0.35),
    ]

    static func named(_ id: String) -> GradientPreset {
        all.first { $0.id == id } ?? all.first { $0.id == "sky" }!
    }

    // MARK: Rendering

    /// Draws into a y-up context. Texture sizes are in points, scaled by `pixelsPerPoint`.
    func draw(in context: CGContext, rect: CGRect, pixelsPerPoint ppp: CGFloat) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)

        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil) {
            switch style {
            case .linear:
                let radians = angle * .pi / 180
                let direction = CGVector(dx: cos(radians), dy: sin(radians))
                let half = (abs(rect.width * direction.dx) + abs(rect.height * direction.dy)) / 2
                let start = CGPoint(x: rect.midX - direction.dx * half, y: rect.midY - direction.dy * half)
                let end = CGPoint(x: rect.midX + direction.dx * half, y: rect.midY + direction.dy * half)
                context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            case .radial:
                // Glow from slightly above center out to the corners.
                let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.12)
                let radius = hypot(rect.width, rect.height) * 0.62
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
            }
        }

        let unit = max(ppp, 0.1)
        switch texture {
        case .none:
            break
        case let .grain(opacity):
            drawGrain(in: context, rect: rect, opacity: opacity, unit: unit)
        case let .dots(color, spacing, radius):
            context.setFillColor(color.cgColor)
            let step = spacing * unit, r = radius * unit
            var row = 0
            var y = rect.minY + step / 2
            while y < rect.maxY + step {
                // Offset alternate rows for a classic polka pattern.
                var x = rect.minX + step / 2 + (row.isMultiple(of: 2) ? 0 : step / 2)
                while x < rect.maxX + step {
                    context.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += step
                }
                y += step
                row += 1
            }
            context.fillPath()
        case let .grid(color, spacing):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(max(1, unit))
            let step = spacing * unit
            var x = rect.minX
            while x <= rect.maxX { context.move(to: CGPoint(x: x, y: rect.minY)); context.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
            var y = rect.minY
            while y <= rect.maxY { context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step }
            context.strokePath()
        case let .lines(color, spacing, width):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width * unit)
            let step = spacing * unit
            var offset = -rect.height
            while offset < rect.width {
                context.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
                context.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.maxY))
                offset += step
            }
            context.strokePath()
        case let .crosshatch(color, spacing):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(max(0.5, unit * 0.75))
            let step = spacing * unit
            var x = rect.minX
            while x <= rect.maxX { context.move(to: CGPoint(x: x, y: rect.minY)); context.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
            var y = rect.minY
            while y <= rect.maxY { context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step * 1.3 }
            context.strokePath()
        case let .flecks(palette, spacing):
            // One chip per cell, jittered by a hash of the cell, so the pattern is
            // identical at any resolution (live preview and export match).
            let columns = Int(ceil(rect.width / unit / spacing)), rows = Int(ceil(rect.height / unit / spacing))
            for row in 0...rows {
                for column in 0...columns {
                    var h = Self.hash(column, row)
                    func next() -> Double { h = h &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Double(h >> 11) / Double(1 << 53) }
                    let x = (Double(column) + next()) * spacing, y = (Double(row) + next()) * spacing
                    let size = 1.4 + next() * 4.2, aspect = 0.55 + next() * 0.45, rotation = next() * .pi
                    let color = palette[Int(next() * Double(palette.count)) % palette.count]
                    context.saveGState()
                    context.translateBy(x: rect.minX + x * unit, y: rect.minY + y * unit)
                    context.rotate(by: rotation)
                    context.setFillColor(color.cgColor)
                    context.fillEllipse(in: CGRect(x: -size * unit / 2, y: -size * aspect * unit / 2, width: size * unit, height: size * aspect * unit))
                    context.restoreGState()
                }
            }
        case let .contours(color, spacing, amplitude):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(max(0.75, unit))
            context.setLineJoin(.round)
            let widthPoints = rect.width / unit, heightPoints = rect.height / unit
            var line = 0
            var base = -amplitude * 2
            while base < heightPoints + amplitude * 2 {
                let phase = Double(line) * 0.55
                var x = 0.0
                context.move(to: CGPoint(x: rect.minX, y: rect.minY + (base + amplitude * sin(phase)) * unit))
                while x <= widthPoints + 4 {
                    // Two overlapping waves give an organic, map-like contour.
                    let y = base + amplitude * sin(x / 37 + phase) + amplitude * 0.55 * sin(x / 13 + phase * 1.7)
                    context.addLine(to: CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit))
                    x += 4
                }
                base += spacing
                line += 1
            }
            context.strokePath()
        case let .halftone(color, spacing, maxRadius):
            context.setFillColor(color.cgColor)
            let widthPoints = rect.width / unit, heightPoints = rect.height / unit
            var y = spacing / 2
            while y < heightPoints + spacing {
                var x = spacing / 2
                while x < widthPoints + spacing {
                    // Dots grow from the top-left toward the bottom-right corner (y-up: bottom = minY).
                    let t = (x / max(widthPoints, 1) + (1 - y / max(heightPoints, 1))) / 2
                    let r = maxRadius * min(max(t, 0.05), 1) * unit
                    context.addEllipse(in: CGRect(x: rect.minX + x * unit - r, y: rect.minY + y * unit - r, width: r * 2, height: r * 2))
                    x += spacing
                }
                y += spacing * 0.866
            }
            context.fillPath()
        case let .isometric(color, spacing):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(max(0.75, unit))
            let step = spacing * unit
            let rowHeight = step * 0.866
            var y = rect.minY
            while y <= rect.maxY { context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y)); y += rowHeight }
            // Two families of 60° lines.
            let run = rect.height / tan(.pi / 3)
            var offset = -run
            while offset < rect.width + run {
                context.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
                context.addLine(to: CGPoint(x: rect.minX + offset + run, y: rect.maxY))
                context.move(to: CGPoint(x: rect.minX + offset + run, y: rect.minY))
                context.addLine(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
                offset += step
            }
            context.strokePath()
        }

        if grain > 0 {
            drawGrain(in: context, rect: rect, opacity: grain, unit: unit)
        }
    }

    private func drawGrain(in context: CGContext, rect: CGRect, opacity: Double, unit: CGFloat) {
        context.saveGState()
        context.setAlpha(opacity)
        context.setBlendMode(.overlay)
        let side = 128 * unit / 2 // the 128px tile spans 64pt
        context.draw(Self.noiseTile, in: CGRect(x: rect.minX, y: rect.minY, width: side, height: side), byTiling: true)
        context.restoreGState()
    }

    private static func hash(_ a: Int, _ b: Int) -> UInt64 {
        var h = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= h >> 29
        return h &* 0xBF58_476D_1CE4_E5B9
    }

    /// A deterministic 128×128 tile of gray noise for the grain texture.
    nonisolated(unsafe) static let noiseTile: CGImage = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side)
        var seed: UInt32 = 0x9E3779B9
        for i in pixels.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }()
}

enum BackdropFill: Codable, Equatable {
    case gradient(id: String)
    case solid(RGBAColor)
    case image(path: String)
    case transparent
}

enum CanvasAspect: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto"
    case square = "1:1"
    case fourThree = "4:3"
    case sixteenNine = "16:9"

    var id: String { rawValue }

    var ratio: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .sixteenNine: 16.0 / 9.0
        }
    }
}

/// Background, padding, rounding and shadow placed around the screenshot.
/// Lengths are in points, so the look is the same on Retina and non-Retina captures.
struct Backdrop: Codable, Equatable {
    var enabled = false
    var fill: BackdropFill = .gradient(id: "sky")
    var padding: Double = 64
    var cornerRadius: Double = 12
    var shadowBlur: Double = 40
    var shadowOpacity: Double = 0.45
    var shadowOffset: Double = 12
    var aspect: CanvasAspect = .auto

    // MARK: Persistence (the last-used look carries over to the next screenshot)

    private static let defaultsKey = "lastBackdrop"

    static func loadLastUsed() -> Backdrop {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let backdrop = try? JSONDecoder().decode(Backdrop.self, from: data) else { return Backdrop() }
        return backdrop
    }

    func saveAsLastUsed() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Geometry

    /// Pixel size of the final canvas for content of `contentSize` pixels.
    func canvasSize(forContent contentSize: CGSize, pixelsPerPoint: CGFloat) -> CGSize {
        guard enabled else { return contentSize }
        let pad = padding * pixelsPerPoint
        var width = contentSize.width + pad * 2
        var height = contentSize.height + pad * 2
        if let ratio = aspect.ratio {
            if width / height < ratio {
                width = height * ratio
            } else {
                height = width / ratio
            }
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    // MARK: Rendering

    /// Composites `content` onto the backdrop. Thread-safe; used for preview and export.
    func compose(_ content: CGImage, pixelsPerPoint ppp: CGFloat, backgroundImage: CGImage?) -> CGImage? {
        guard enabled else { return content }
        let contentSize = CGSize(width: content.width, height: content.height)
        let canvas = canvasSize(forContent: contentSize, pixelsPerPoint: ppp)

        let colorSpace: CGColorSpace = {
            if let space = content.colorSpace, space.model == .rgb, space.supportsOutput { return space }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        guard let context = CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high

        let bounds = CGRect(origin: .zero, size: canvas)
        drawFill(in: context, rect: bounds, backgroundImage: backgroundImage, pixelsPerPoint: ppp)

        let imageRect = CGRect(
            x: ((canvas.width - contentSize.width) / 2).rounded(),
            y: ((canvas.height - contentSize.height) / 2).rounded(),
            width: contentSize.width,
            height: contentSize.height
        )
        let radius = min(cornerRadius * ppp, min(imageRect.width, imageRect.height) / 2)
        let shape = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if shadowOpacity > 0, shadowBlur > 0 || shadowOffset > 0 {
            context.saveGState()
            // Shadow geometry is in device pixels; y-up, so a downward shadow is negative.
            context.setShadow(
                offset: CGSize(width: 0, height: -shadowOffset * ppp),
                blur: shadowBlur * ppp,
                color: CGColor(gray: 0, alpha: shadowOpacity)
            )
            context.addPath(shape)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.clear(imageRect) // Don't let the shadow's fill show through transparent pixels.
        context.draw(content, in: imageRect)
        context.restoreGState()

        return context.makeImage()
    }

    /// Draws the fill into a y-up context (used by export and the live editor).
    /// Texture sizes are in points, scaled by `pixelsPerPoint`.
    func drawFill(in context: CGContext, rect: CGRect, backgroundImage: CGImage?, pixelsPerPoint: CGFloat) {
        switch fill {
        case .transparent:
            break
        case let .solid(color):
            context.setFillColor(color.cgColor)
            context.fill(rect)
        case let .gradient(id):
            GradientPreset.named(id).draw(in: context, rect: rect, pixelsPerPoint: pixelsPerPoint)
        case .image:
            guard let backgroundImage else { return }
            // Aspect-fill the canvas.
            let imageSize = CGSize(width: backgroundImage.width, height: backgroundImage.height)
            let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            context.saveGState()
            context.clip(to: rect)
            context.interpolationQuality = .high
            context.draw(backgroundImage, in: CGRect(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
            context.restoreGState()
        }
    }

    /// Loads a background image, downsampled so large wallpapers stay fast.
    static func loadBackgroundImage(path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3200,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
