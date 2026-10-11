// Generates Resources/AppIcon.icns: a fold-out pocket loupe drawn as a grayscale
// technical wireframe (lens arm swung partway out from under its cover, hidden edges
// dashed), with colored magnified pixels showing through the glass.
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
        gradient([rgb(0.97, 0.97, 0.975), rgb(0.92, 0.92, 0.93)]),
        start: CGPoint(x: 300, y: body.maxY), end: CGPoint(x: 724, y: body.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    // Gentle light from the top-left.
    ctx.drawRadialGradient(
        gradient([CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)]),
        startCenter: CGPoint(x: 330, y: 820), startRadius: 0,
        endCenter: CGPoint(x: 330, y: 820), endRadius: 620, options: []
    )

    // Faint drafting grid on the paper.
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.045))
    ctx.setLineWidth(2)
    var gridX = body.minX + 32
    while gridX < body.maxX { ctx.move(to: CGPoint(x: gridX, y: body.minY)); ctx.addLine(to: CGPoint(x: gridX, y: body.maxY)); gridX += 64 }
    var gridY = body.minY + 32
    while gridY < body.maxY { ctx.move(to: CGPoint(x: body.minX, y: gridY)); ctx.addLine(to: CGPoint(x: body.maxX, y: gridY)); gridY += 64 }
    ctx.strokePath()

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

    // Wireframe style: grayscale line art on paper; only the pixels in the lens have color.
    let ink = rgb(0.20, 0.20, 0.22)       // primary outlines
    let pencil = rgb(0.55, 0.55, 0.58)    // secondary detail and hidden edges
    let guide = rgb(0.68, 0.68, 0.71)     // construction lines
    let paper = rgb(0.985, 0.985, 0.99)   // fills that hide what's behind a part
    let outline: CGFloat = 15
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
    func dashed(_ draw: () -> Void, width: CGFloat, color: CGColor, dash: [CGFloat]) {
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: dash)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color)
        draw()
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Construction lines (behind everything)
    dashed({
        ctx.move(to: pivot); ctx.addLine(to: CGPoint(x: pivot.x + cos(lensAngle) * (armLength + lensRadius + 40), y: pivot.y + sin(lensAngle) * (armLength + lensRadius + 40)))
        ctx.move(to: pivot); ctx.addLine(to: CGPoint(x: pivot.x + cos(caseAngle) * (armLength + lensRadius + 20), y: pivot.y + sin(caseAngle) * (armLength + lensRadius + 20)))
    }, width: 3.5, color: guide, dash: [18, 12])

    // MARK: Lens arm
    ctx.addPath(armPath)
    ctx.setFillColor(paper)
    ctx.fillPath()

    // Magnified pixels seen through the lens — the only color in the icon.
    let glassRadius = lensRadius - 40
    let glass = CGPath(ellipseIn: circle(lensCenter, glassRadius), transform: nil)
    ctx.saveGState()
    ctx.addPath(glass)
    ctx.clip()
    let cell: CGFloat = 54
    let palette = [color(1, 0.36, 0.36), color(1, 0.76, 0.22), color(0.3, 0.84, 0.52), color(0.32, 0.62, 1), color(0.72, 0.45, 1)]
    var seed: UInt32 = 7
    for row in -4...4 {
        for column in -4...4 {
            seed = seed &* 1_103_515_245 &+ 12345
            let pixelColor = palette[Int((seed >> 16) % UInt32(palette.count))]
            let rect = CGRect(x: lensCenter.x + CGFloat(column) * cell - cell / 2,
                              y: lensCenter.y + CGFloat(row) * cell - cell / 2, width: cell, height: cell)
            ctx.setFillColor(pixelColor.copy(alpha: 0.9)!)
            ctx.fill(rect.insetBy(dx: 4, dy: 4))
        }
    }
    ctx.restoreGState()

    ctx.addPath(armPath)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(outline)
    ctx.strokePath()
    // Glass and the rim's inner edge.
    ctx.addPath(glass)
    ctx.setLineWidth(11)
    ctx.strokePath()
    ctx.setStrokeColor(pencil)
    ctx.setLineWidth(4)
    ctx.strokeEllipse(in: circle(lensCenter, glassRadius + 18))

    // MARK: Cover (on top of the lens arm)
    ctx.addPath(casePath)
    ctx.setFillColor(paper)
    ctx.fillPath()
    // Hidden edges of the arm under the cover, dashed like a technical drawing.
    ctx.saveGState()
    ctx.addPath(casePath)
    ctx.clip()
    dashed({ ctx.addPath(armPath) }, width: 5, color: pencil, dash: [16, 12])
    ctx.restoreGState()
    // The seat the lens folds into, with its center mark.
    ctx.setStrokeColor(pencil)
    ctx.setLineWidth(5)
    ctx.strokeEllipse(in: circle(caseCenter, lensRadius - 62))
    dashed({
        ctx.move(to: CGPoint(x: caseCenter.x - 28, y: caseCenter.y)); ctx.addLine(to: CGPoint(x: caseCenter.x + 28, y: caseCenter.y))
        ctx.move(to: CGPoint(x: caseCenter.x, y: caseCenter.y - 28)); ctx.addLine(to: CGPoint(x: caseCenter.x, y: caseCenter.y + 28))
    }, width: 3.5, color: guide, dash: [10, 7])
    ctx.addPath(casePath)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(outline)
    ctx.strokePath()

    // MARK: Rivet at the pivot
    let rivetRadius: CGFloat = 40
    ctx.setFillColor(paper)
    ctx.fillEllipse(in: circle(pivot, rivetRadius))
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(10)
    ctx.strokeEllipse(in: circle(pivot, rivetRadius))
    ctx.setStrokeColor(pencil)
    ctx.setLineWidth(4)
    ctx.strokeEllipse(in: circle(pivot, 14))
    // Crosshair centerlines through the pivot.
    dashed({
        ctx.move(to: CGPoint(x: pivot.x - 66, y: pivot.y)); ctx.addLine(to: CGPoint(x: pivot.x + 66, y: pivot.y))
        ctx.move(to: CGPoint(x: pivot.x, y: pivot.y - 66)); ctx.addLine(to: CGPoint(x: pivot.x, y: pivot.y + 66))
    }, width: 3.5, color: guide, dash: [12, 8])

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
