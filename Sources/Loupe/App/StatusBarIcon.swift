import AppKit

/// The menu bar glyph: a fold-out loupe (lens arm swung out from its cover),
/// matching the app icon. Drawn as a template so it adapts to light/dark menu bars.
enum StatusBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let pivot = CGPoint(x: 3.6, y: 3.6)
            let cover = paddle(pivot: pivot, pivotRadius: 1.7, length: 9.2, radius: 3.9, angle: 0.08)
            let arm = paddle(pivot: pivot, pivotRadius: 1.7, length: 8.6, radius: 4.4, angle: 1.0)
            let lensCenter = CGPoint(x: pivot.x + cos(1.0) * 8.6, y: pivot.y + sin(1.0) * 8.6)

            // Cover: solid, with the arm's outline knocked out so the two read as separate parts.
            context.addPath(cover)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.setBlendMode(.clear)
            context.addPath(arm)
            context.setLineWidth(2.6)
            context.drawPath(using: .fillStroke)
            context.setBlendMode(.normal)

            // Lens arm: outlined, with the glass left open.
            context.addPath(arm)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(1.3)
            context.strokePath()
            context.addEllipse(in: CGRect(x: lensCenter.x - 2.5, y: lensCenter.y - 2.5, width: 5, height: 5))
            context.setLineWidth(1.0)
            context.strokePath()
            // Glint on the glass.
            context.addArc(center: lensCenter, radius: 1.3, startAngle: .pi * 0.55, endAngle: .pi * 0.95, clockwise: false)
            context.setLineWidth(0.8)
            context.setLineCap(.round)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Loupe"
        return image
    }

    /// Convex hull of a small circle at the pivot and a large circle `length` away along `angle`.
    private static func paddle(pivot: CGPoint, pivotRadius r1: CGFloat, length: CGFloat, radius r2: CGFloat, angle: CGFloat) -> CGPath {
        let alpha = asin((r2 - r1) / length)
        let top = CGFloat.pi / 2 + alpha
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: r1, startAngle: top, endAngle: -top, clockwise: false)
        path.addArc(center: CGPoint(x: length, y: 0), radius: r2, startAngle: -top, endAngle: top, clockwise: false)
        path.closeSubpath()
        var transform = CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: angle)
        return path.copy(using: &transform)!
    }
}
