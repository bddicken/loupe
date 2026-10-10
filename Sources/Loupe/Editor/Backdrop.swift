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

struct GradientPreset: Identifiable {
    let id: String
    let colors: [RGBAColor]
    /// Direction in degrees, y-up: 0 = left→right, -45 = top-left→bottom-right.
    let angle: Double

    init(_ id: String, _ hexes: [UInt32], angle: Double = -45) {
        self.id = id
        colors = hexes.map(RGBAColor.init(hex:))
        self.angle = angle
    }

    static let all: [GradientPreset] = [
        GradientPreset("sky", [0x56CCF2, 0x2F80ED]),
        GradientPreset("ocean", [0x2E3192, 0x1BFFFF]),
        GradientPreset("violet", [0x8E2DE2, 0x4A00E0]),
        GradientPreset("berry", [0xFC466B, 0x3F5EFB]),
        GradientPreset("candy", [0xF857A6, 0xFF5858]),
        GradientPreset("sunset", [0xFF7E5F, 0xFEB47B]),
        GradientPreset("citrus", [0xF7971E, 0xFFD200]),
        GradientPreset("mint", [0x00B09B, 0x96C93D]),
        GradientPreset("aurora", [0x00C9FF, 0x92FE9D]),
        GradientPreset("peach", [0xFFDEE9, 0xB5FFFC]),
        GradientPreset("cream", [0xFDFCFB, 0xE2D1C3]),
        GradientPreset("dusk", [0x2C3E50, 0xFD746C]),
        GradientPreset("midnight", [0x232526, 0x414345]),
        GradientPreset("graphite", [0x434343, 0x000000]),
    ]

    static func named(_ id: String) -> GradientPreset {
        all.first { $0.id == id } ?? all[0]
    }

    /// Unit-square start/end points for SwiftUI (y-down) matching the CG rendering.
    var swiftUIPoints: (start: UnitPoint, end: UnitPoint) {
        let radians = angle * .pi / 180
        let dx = cos(radians) / 2, dy = sin(radians) / 2
        return (UnitPoint(x: 0.5 - dx, y: 0.5 + dy), UnitPoint(x: 0.5 + dx, y: 0.5 - dy))
    }
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
        drawFill(in: context, rect: bounds, backgroundImage: backgroundImage)

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

    private func drawFill(in context: CGContext, rect: CGRect, backgroundImage: CGImage?) {
        switch fill {
        case .transparent:
            break
        case let .solid(color):
            context.setFillColor(color.cgColor)
            context.fill(rect)
        case let .gradient(id):
            let preset = GradientPreset.named(id)
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: preset.colors.map(\.cgColor) as CFArray,
                locations: nil
            ) else { return }
            let radians = preset.angle * .pi / 180
            let direction = CGVector(dx: cos(radians), dy: sin(radians))
            let half = (abs(rect.width * direction.dx) + abs(rect.height * direction.dy)) / 2
            let start = CGPoint(x: rect.midX - direction.dx * half, y: rect.midY - direction.dy * half)
            let end = CGPoint(x: rect.midX + direction.dx * half, y: rect.midY + direction.dy * half)
            context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .image:
            guard let backgroundImage else { return }
            // Aspect-fill the canvas.
            let imageSize = CGSize(width: backgroundImage.width, height: backgroundImage.height)
            let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            context.draw(backgroundImage, in: CGRect(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
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
