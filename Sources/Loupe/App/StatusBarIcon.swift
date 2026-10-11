import AppKit

/// The menu bar glyph: the app icon's wireframe fold-out loupe (lens arm swung out
/// from under its cover, pixels in the glass). Drawn as a template so it adapts to light/dark menu bars.
enum StatusBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let pivot = CGPoint(x: 3.6, y: 3.6)
            let cover = paddle(pivot: pivot, pivotRadius: 1.7, length: 9.2, radius: 3.9, angle: 0.08)
            let arm = paddle(pivot: pivot, pivotRadius: 1.7, length: 8.6, radius: 4.4, angle: 1.0)
            let lensCenter = CGPoint(x: pivot.x + cos(1.0) * 8.6, y: pivot.y + sin(1.0) * 8.6)

            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.setLineJoin(.round)

            // Lens arm (underneath), as an outline.
            context.addPath(arm)
            context.setLineWidth(1.25)
            context.strokePath()
            // The glass, with a few magnified "pixels" inside (the app icon's colored grid).
            context.setLineWidth(1.0)
            context.strokeEllipse(in: CGRect(x: lensCenter.x - 2.7, y: lensCenter.y - 2.7, width: 5.4, height: 5.4))
            let cell: CGFloat = 1.3
            for row in 0..<2 {
                for column in 0..<2 {
                    context.fill(CGRect(
                        x: lensCenter.x - cell + CGFloat(column) * cell + 0.15,
                        y: lensCenter.y - cell + CGFloat(row) * cell + 0.15,
                        width: cell - 0.3, height: cell - 0.3
                    ))
                }
            }

            // Cover (on top): clear a gap around it so the parts read as separate, then outline it.
            context.setBlendMode(.clear)
            context.addPath(cover)
            context.setLineWidth(2.6)
            context.drawPath(using: .fillStroke)
            context.setBlendMode(.normal)
            context.addPath(cover)
            context.setLineWidth(1.25)
            context.strokePath()
            // Rivet at the pivot.
            context.setLineWidth(0.9)
            context.strokeEllipse(in: CGRect(x: pivot.x - 0.95, y: pivot.y - 0.95, width: 1.9, height: 1.9))
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
