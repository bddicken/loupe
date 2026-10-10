// Generates site/og-image.png (1200×630): the app icon and the word "Loupe"
// on a very dark gray background, for link previews.
// Usage: swift scripts/make-og-image.swift Resources/AppIcon.png site/og-image.png
import AppKit

let arguments = CommandLine.arguments
let iconPath = arguments.count > 1 ? arguments[1] : "Resources/AppIcon.png"
let outputPath = arguments.count > 2 ? arguments[2] : "site/og-image.png"

guard let icon = NSImage(contentsOfFile: iconPath) else {
    fatalError("Couldn't read \(iconPath)")
}

let size = NSSize(width: 1200, height: 630)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor(srgbRed: 0.075, green: 0.075, blue: 0.085, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

let title = NSAttributedString(string: "Loupe", attributes: [
    .font: NSFont.systemFont(ofSize: 168, weight: .bold),
    .foregroundColor: NSColor(white: 0.97, alpha: 1),
    .kern: -3,
])
let titleSize = title.size()

// The icon's artwork has transparent margins (the macOS icon grid), so it's
// drawn a bit larger than it looks and overlapped slightly with the gap.
let iconSide: CGFloat = 400
let gap: CGFloat = 8
let groupWidth = iconSide + gap + titleSize.width
let originX = (size.width - groupWidth) / 2

icon.draw(
    in: NSRect(x: originX, y: (size.height - iconSide) / 2, width: iconSide, height: iconSide),
    from: .zero, operation: .sourceOver, fraction: 1
)
title.draw(at: NSPoint(
    x: originX + iconSide + gap,
    y: (size.height - titleSize.height) / 2 + 6
))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
