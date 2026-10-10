// Generates Resources/AppIcon.icns: a fold-out pocket loupe, lens arm swung
// partway out from under its outer cover, with magnified pixels showing through the glass.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// The icon is grayscale except for the pixels seen through the lens, so
/// every color is reduced to its luminance here; the pixels use `color` instead.
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    let gray = 0.299 * r + 0.587 * g + 0.114 * b
    return CGColor(srgbRed: gray, green: gray, blue: gray, alpha: a)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

/// A "paddle": the convex hull of a small circle at the pivot and a large
/// circle at distance `length` along `angle` — the shape of a loupe's arm.
func paddle(pivot: CGPoint, pivotRadius r1: CGFloat, length: CGFloat, radius r2: CGFloat, angle: CGFloat) -> CGPath {
    let alpha = asin((r2 - r1) / length)
    let path = CGMutablePath()
    let top = CGFloat.pi / 2 + alpha
    path.addArc(center: .zero, radius: r1, startAngle: top, endAngle: -top, clockwise: false)
    path.addArc(center: CGPoint(x: length, y: 0), radius: r2, startAngle: -top, endAngle: top, clockwise: false)
    path.closeSubpath()
    var transform = CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: angle)
    return path.copy(using: &transform)!
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // MARK: Background body (macOS icon grid: 824pt rounded square)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0.90, 0.90, 0.91), rgb(0.78, 0.78, 0.80)]),
        start: CGPoint(x: 300, y: body.maxY), end: CGPoint(x: 724, y: body.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    // Gentle light from the top-left.
    ctx.drawRadialGradient(
        gradient([CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)]),
        startCenter: CGPoint(x: 330, y: 820), startRadius: 0,
        endCenter: CGPoint(x: 330, y: 820), endRadius: 620, options: []
    )

    // MARK: Loupe geometry
    let pivot = CGPoint(x: 278, y: 324)
    let caseAngle: CGFloat = 0.10 // the cover, nearly flat
    let lensAngle: CGFloat = 1.00 // the lens arm, swung out ~50°
    let armLength: CGFloat = 385
    let lensRadius: CGFloat = 205
    let pivotRadius: CGFloat = 78

    let casePath = paddle(pivot: pivot, pivotRadius: pivotRadius, length: armLength, radius: lensRadius - 12, angle: caseAngle)
    let armPath = paddle(pivot: pivot, pivotRadius: pivotRadius, length: armLength, radius: lensRadius, angle: lensAngle)
    let lensCenter = CGPoint(x: pivot.x + cos(lensAngle) * armLength, y: pivot.y + sin(lensAngle) * armLength)
    let caseCenter = CGPoint(x: pivot.x + cos(caseAngle) * armLength, y: pivot.y + sin(caseAngle) * armLength)

    // MARK: Lens arm (polished metal)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: CGColor(gray: 0, alpha: 0.5))
    ctx.addPath(armPath)
    ctx.setFillColor(rgb(0.7, 0.72, 0.76))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(armPath)
    ctx.clip()
    // Brushed-metal banding across the arm.
    ctx.drawLinearGradient(
        gradient(
            [rgb(0.96, 0.97, 0.99), rgb(0.70, 0.72, 0.77), rgb(0.88, 0.90, 0.93), rgb(0.55, 0.57, 0.63), rgb(0.80, 0.82, 0.86)],
            [0, 0.3, 0.5, 0.75, 1]
        ),
        start: CGPoint(x: lensCenter.x - 260, y: lensCenter.y + 260), end: CGPoint(x: lensCenter.x + 200, y: pivot.y - 120),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()
    ctx.addPath(armPath)
    ctx.setStrokeColor(rgb(0.35, 0.37, 0.43, 0.8))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // MARK: Glass
    let glassRadius = lensRadius - 34
    let glass = CGPath(ellipseIn: CGRect(x: lensCenter.x - glassRadius, y: lensCenter.y - glassRadius,
                                        width: glassRadius * 2, height: glassRadius * 2), transform: nil)
    // Inner bevel of the rim.
    ctx.addPath(CGPath(ellipseIn: CGRect(x: lensCenter.x - glassRadius - 8, y: lensCenter.y - glassRadius - 8,
                                         width: (glassRadius + 8) * 2, height: (glassRadius + 8) * 2), transform: nil))
    ctx.setFillColor(rgb(0.38, 0.40, 0.46))
    ctx.fillPath()

    ctx.saveGState()
    ctx.addPath(glass)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([rgb(0.80, 0.92, 1.0), rgb(0.42, 0.66, 0.95), rgb(0.20, 0.36, 0.72)], [0, 0.6, 1]),
        startCenter: CGPoint(x: lensCenter.x - 50, y: lensCenter.y + 60), startRadius: 0,
        endCenter: lensCenter, endRadius: glassRadius, options: []
    )

    // Magnified pixels seen through the lens (a nod to screenshots).
    let cell: CGFloat = 54
    let palette = [color(1, 0.36, 0.36), color(1, 0.76, 0.22), color(0.3, 0.84, 0.52), color(0.32, 0.62, 1), color(0.72, 0.45, 1)]
    var seed: UInt32 = 7
    for row in -4...4 {
        for column in -4...4 {
            seed = seed &* 1_103_515_245 &+ 12345
            let pixelColor = palette[Int((seed >> 16) % UInt32(palette.count))]
            let rect = CGRect(x: lensCenter.x + CGFloat(column) * cell - cell / 2,
                              y: lensCenter.y + CGFloat(row) * cell - cell / 2, width: cell, height: cell)
            ctx.setFillColor(pixelColor.copy(alpha: 0.78)!)
            ctx.fill(rect.insetBy(dx: 3, dy: 3))
        }
    }
    // Lens curvature: darker toward the edge.
    ctx.drawRadialGradient(
        gradient([CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.35)], [0.55, 1]),
        startCenter: lensCenter, startRadius: 0, endCenter: lensCenter, endRadius: glassRadius, options: []
    )
    // Specular highlight.
    ctx.addEllipse(in: CGRect(x: lensCenter.x - glassRadius * 0.72, y: lensCenter.y + glassRadius * 0.12,
                              width: glassRadius * 0.95, height: glassRadius * 0.62))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([CGColor(gray: 1, alpha: 0.75), CGColor(gray: 1, alpha: 0)]),
        start: CGPoint(x: lensCenter.x, y: lensCenter.y + glassRadius), end: CGPoint(x: lensCenter.x, y: lensCenter.y + glassRadius * 0.1),
        options: []
    )
    ctx.restoreGState()

    ctx.addPath(glass)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
    ctx.setLineWidth(3)
    ctx.strokePath()

    // MARK: Cover (dark outer case, on top of the lens arm)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(casePath)
    ctx.setFillColor(rgb(0.13, 0.13, 0.17))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(casePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0.30, 0.30, 0.36), rgb(0.10, 0.10, 0.13)]),
        start: CGPoint(x: caseCenter.x, y: caseCenter.y + lensRadius), end: CGPoint(x: caseCenter.x, y: caseCenter.y - lensRadius),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    // Embossed ring where the lens sits when folded.
    ctx.addArc(center: caseCenter, radius: lensRadius - 62, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
    ctx.setLineWidth(10)
    ctx.strokePath()
    ctx.addArc(center: CGPoint(x: caseCenter.x, y: caseCenter.y - 4), radius: lensRadius - 62, startAngle: .pi * 1.1, endAngle: .pi * 1.9, clockwise: false)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(casePath)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
    ctx.setLineWidth(5)
    ctx.strokePath()

    // MARK: Rivet at the pivot
    let rivetRadius: CGFloat = 40
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: CGColor(gray: 0, alpha: 0.5))
    ctx.addEllipse(in: CGRect(x: pivot.x - rivetRadius, y: pivot.y - rivetRadius, width: rivetRadius * 2, height: rivetRadius * 2))
    ctx.setFillColor(rgb(0.6, 0.62, 0.66))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: pivot.x - rivetRadius, y: pivot.y - rivetRadius, width: rivetRadius * 2, height: rivetRadius * 2))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0.98, 0.98, 1), rgb(0.48, 0.5, 0.56)]),
        start: CGPoint(x: pivot.x - rivetRadius, y: pivot.y + rivetRadius), end: CGPoint(x: pivot.x + rivetRadius, y: pivot.y - rivetRadius),
        options: []
    )
    ctx.restoreGState()
    ctx.addEllipse(in: CGRect(x: pivot.x - 11, y: pivot.y - 11, width: 22, height: 22))
    ctx.setFillColor(rgb(0.36, 0.38, 0.44))
    ctx.fillPath()

    ctx.restoreGState() // body clip
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = CGFloat(base * multiplier)
        let name = multiplier == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: pixels).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: output.deletingPathExtension().appendingPathExtension("png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(process.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
