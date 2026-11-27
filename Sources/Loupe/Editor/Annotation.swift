import AppKit

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, step, blur, pixelate, redact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .step: "Counter"
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .redact: "Redact"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .step: "1.circle"
        case .blur: "drop.halffull"
        case .pixelate: "squareshape.split.3x3"
        case .redact: "rectangle.fill"
        }
    }

    /// Single-key shortcut used while the canvas has focus.
    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .step: "n"
        case .blur: "b"
        case .pixelate: "x"
        case .redact: "d"
        }
    }

    var kind: Annotation.Kind? {
        switch self {
        case .select: nil
        case .arrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .pen: .pen
        case .highlighter: .highlighter
        case .text: .text
        case .step: .step
        case .blur: .blur
        case .pixelate: .pixelate
        case .redact: .redact
        }
    }
}

/// The typeface of a text annotation: one of the system font's designs, or an installed family.
enum TextFont: Hashable {
    case system, rounded, serif, monospaced
    case family(String)

    static let systemDesigns: [TextFont] = [.system, .rounded, .serif, .monospaced]

    /// Installed font families, by name (without the system's hidden ones).
    static let installedFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    var title: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Mono"
        case let .family(name): name
        }
    }

    /// For UserDefaults.
    var storedValue: String {
        switch self {
        case .system: "system"
        case .rounded: "rounded"
        case .serif: "serif"
        case .monospaced: "monospaced"
        case let .family(name): "family:" + name
        }
    }

    init(storedValue: String) {
        switch storedValue {
        case "rounded": self = .rounded
        case "serif": self = .serif
        case "monospaced": self = .monospaced
        case let value where value.hasPrefix("family:"): self = .family(String(value.dropFirst("family:".count)))
        default: self = .system
        }
    }
}

enum TextWeight: String, CaseIterable, Identifiable {
    case light, regular, medium, semibold, bold, heavy

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var nsWeight: NSFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}

/// A markup element. Coordinates are in the *source* image's pixel space
/// (top-left origin, before rotation/crop) so annotations follow the image
/// through rotate, flip and crop.
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case arrow, line, rectangle, ellipse, pen, highlighter, text, step, blur, pixelate
        /// A solid, opaque box: unlike blur and pixelate, nothing underneath can be recovered.
        case redact

        var isRegionEffect: Bool { self == .blur || self == .pixelate }
        var isFreehand: Bool { self == .pen || self == .highlighter }
        var isBoxed: Bool { self == .rectangle || self == .ellipse || self == .redact || isRegionEffect }
        /// Kinds that can have a drop shadow: the drawn ones, but not the highlighter
        /// (it tints what's under it), redactions or blur/pixelate regions.
        var castsShadow: Bool {
            switch self {
            case .arrow, .line, .rectangle, .ellipse, .pen, .text, .step: true
            case .highlighter, .blur, .pixelate, .redact: false
            }
        }
    }

    /// Blur and pixelate strength, from weak to strong.
    static let strengthRange: ClosedRange<Double> = 1...10

    var id = UUID()
    var kind: Kind
    /// Two points (start, end) for shapes; the stroke for freehand; one point
    /// (top-left for text, center for counters) otherwise.
    var points: [CGPoint]
    var color: RGBAColor
    var strokeWidth: CGFloat
    var fontSize: CGFloat
    var text = ""
    /// Text only: the width (source pixels, upright) it wraps at, or nil to grow with its longest line.
    var textWidth: CGFloat?
    var number = 0
    /// Blur and pixelate only: how strong the effect is (in `strengthRange`).
    var strength = 4.0
    /// Text only: its typeface and weight.
    var font = TextFont.system
    var fontWeight = TextWeight.bold
    /// Whether it has a soft drop shadow (only for kinds that `castsShadow`).
    var shadow = true

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Label for the layers list.
    var layerName: String {
        switch kind {
        case .text: text.isEmpty ? "Text" : "“\(text.replacingOccurrences(of: "\n", with: " "))”"
        case .step: "Counter \(number)"
        default: AnnotationTool.allCases.first { $0.kind == kind }?.title ?? "Shape"
        }
    }

    var symbol: String {
        AnnotationTool.allCases.first { $0.kind == kind }?.symbol ?? "square"
    }

    /// Scales about `anchor` (source pixels). Text and counters grow their
    /// font; strokes keep their width.
    func scaled(by factor: CGFloat, about anchor: CGPoint) -> Annotation {
        var copy = self
        copy.points = points.map { CGPoint(x: anchor.x + ($0.x - anchor.x) * factor, y: anchor.y + ($0.y - anchor.y) * factor) }
        if kind == .text || kind == .step { copy.fontSize = fontSize * factor }
        copy.textWidth = textWidth.map { $0 * factor }
        return copy
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }
}

extension RGBAColor {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// Core Graphics drawing for annotations, shared by the live canvas and export.
/// Draws in source-pixel coordinates into a *flipped* (top-left origin) context.
/// `orientation` is the source → output transform the context draws through:
/// text and counter digits undo its rotation/flip so they always read upright.
enum AnnotationRenderer {
    static func draw(_ annotation: Annotation, in context: CGContext, orientation: CGAffineTransform = .identity) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Core Graphics measures shadows in device pixels, whatever the context's transform
        // (the zoom, a Retina backing store), so scale them from source pixels by hand: the
        // shadow then looks the same in the editor at any zoom as in the saved image.
        let toDevice = context.userSpaceToDeviceSpaceTransform
        let outputScale = sqrt(abs(toDevice.a * toDevice.d - toDevice.b * toDevice.c))
        let shadow = dropShadow(of: annotation).map { shadow in
            (offset: CGSize(width: 0, height: -shadow.offset * outputScale), blur: shadow.blur * outputScale,
             color: CGColor(gray: 0, alpha: shadow.opacity))
        }
        // Counters shadow only their disc (see drawStep).
        if let shadow, annotation.kind != .step {
            context.setShadow(offset: shadow.offset, blur: shadow.blur, color: shadow.color)
        }

        let color = annotation.color.cgColor
        switch annotation.kind {
        case .arrow:
            context.setFillColor(color)
            context.addPath(arrowPath(annotation))
            context.fillPath()
        case .line:
            context.setStrokeColor(color)
            context.setLineWidth(annotation.strokeWidth)
            context.move(to: annotation.start)
            context.addLine(to: annotation.end)
            context.strokePath()
        case .rectangle:
            context.setStrokeColor(color)
            context.setLineWidth(annotation.strokeWidth)
            let radius = min(annotation.strokeWidth, annotation.rect.width / 2, annotation.rect.height / 2)
            context.addPath(CGPath(roundedRect: annotation.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        case .ellipse:
            context.setStrokeColor(color)
            context.setLineWidth(annotation.strokeWidth)
            context.strokeEllipse(in: annotation.rect)
        case .pen:
            context.setStrokeColor(color)
            context.setLineWidth(annotation.strokeWidth)
            context.addPath(freehandPath(annotation.points))
            context.strokePath()
        case .highlighter:
            context.setBlendMode(.multiply)
            context.setStrokeColor(annotation.color.cgColor.copy(alpha: 0.45) ?? color)
            context.setLineWidth(highlighterWidth(annotation))
            context.setLineCap(.square)
            context.addPath(freehandPath(annotation.points))
            context.strokePath()
        case .text:
            context.concatenate(upright(about: annotation.start, orientation))
            let string = NSAttributedString(string: annotation.text, attributes: textAttributes(annotation))
            // As one layer, so the letters shadow what's under the text and not each other.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { context.endTransparencyLayer() }
            if annotation.textWidth != nil {
                // A finite rect (an unbounded one drops lines when rasterized for export),
                // with headroom so rounding never clips the last line.
                var rect = CGRect(origin: annotation.start, size: textSize(annotation))
                rect.size.height += annotation.fontSize
                string.draw(with: rect, options: [.usesLineFragmentOrigin])
            } else {
                string.draw(at: annotation.start)
            }
        case .step:
            context.concatenate(upright(about: annotation.start, orientation))
            drawStep(annotation, in: context, shadow: shadow.map { ($0.blur, $0.color) })
        case .redact:
            // Always opaque, whatever color was picked.
            context.setFillColor(annotation.color.cgColor.copy(alpha: 1) ?? color)
            context.fill(annotation.rect)
        case .blur, .pixelate:
            break // Rendered by Core Image (they need the pixels underneath).
        }
    }

    /// The drop shadow an annotation is drawn with, in source pixels (the shadow falls
    /// straight down by `offset`), or nil without one. Text and counters keep the subtle
    /// one they always had; strokes get one that grows with their width.
    static func dropShadow(of annotation: Annotation) -> (offset: CGFloat, blur: CGFloat, opacity: CGFloat)? {
        guard annotation.shadow, annotation.kind.castsShadow else { return nil }
        switch annotation.kind {
        case .text: return (annotation.fontSize * 0.03, annotation.fontSize * 0.08, 0.25)
        case .step: return (0, stepRadius(annotation) * 0.3, 0.3)
        default: return (annotation.strokeWidth * 0.3, annotation.strokeWidth * 1.5, 0.3)
        }
    }

    static func textAttributes(_ annotation: Annotation) -> [NSAttributedString.Key: Any] {
        [
            .font: font(annotation),
            .foregroundColor: annotation.color.nsColor,
        ]
    }

    /// Resolved fonts, by typeface, weight and size (looking one up is slow, and every redraw needs it).
    private static let fonts = NSCache<NSString, NSFont>()

    /// A text annotation's font. An installed family uses its face nearest the weight;
    /// one that's no longer installed falls back to the system font.
    static func font(_ annotation: Annotation) -> NSFont {
        font(annotation.font, weight: annotation.fontWeight, size: annotation.fontSize)
    }

    static func font(_ font: TextFont, weight: TextWeight, size: CGFloat) -> NSFont {
        let key = "\(font.storedValue)|\(weight.rawValue)|\(size)" as NSString
        if let cached = fonts.object(forKey: key) { return cached }
        let system = NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
        func designed(_ design: NSFontDescriptor.SystemDesign) -> NSFont {
            system.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        }
        let resolved: NSFont = switch font {
        case .system: system
        case .rounded: designed(.rounded)
        case .serif: designed(.serif)
        case .monospaced: designed(.monospaced)
        case let .family(name): familyFont(name, weight: weight, size: size) ?? system
        }
        fonts.setObject(resolved, forKey: key)
        return resolved
    }

    /// The face of an installed family nearest `weight`: an upright one of normal width
    /// if the family has any (so never an italic or a condensed face just for its weight).
    private static func familyFont(_ family: String, weight: TextWeight, size: CGFloat) -> NSFont? {
        var best: (font: NSFont, distance: CGFloat)?
        for member in NSFontManager.shared.availableMembers(ofFontFamily: family) ?? [] {
            guard member.count > 3, let name = member[0] as? String, let font = NSFont(name: name, size: size) else { continue }
            let mask = NSFontTraitMask(rawValue: (member[3] as? NSNumber)?.uintValue ?? 0)
            let isPlain = mask.isDisjoint(with: [.italicFontMask, .condensedFontMask, .expandedFontMask])
            let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            let faceWeight = CGFloat((traits?[.weight] as? NSNumber)?.doubleValue ?? 0)
            let distance = abs(faceWeight - weight.nsWeight.rawValue) + (isPlain ? 0 : 10)
            if best.map({ distance < $0.distance }) ?? true { best = (font, distance) }
        }
        return best?.font
    }

    /// The laid-out size of a text annotation (source pixels, upright): as wide as its
    /// wrap width, or as its longest line; as tall as its lines.
    static func textSize(_ annotation: Annotation) -> CGSize {
        let string = NSAttributedString(string: annotation.text.isEmpty ? " " : annotation.text, attributes: textAttributes(annotation))
        guard let width = annotation.textWidth else { return string.size() }
        let used = string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return CGSize(width: width, height: ceil(used.height))
    }

    /// Undoes the rotation/flip in `orientation` about `anchor` (in source pixels).
    static func upright(about anchor: CGPoint, _ orientation: CGAffineTransform) -> CGAffineTransform {
        let t = orientation
        let scale = sqrt(abs(t.a * t.d - t.b * t.c))
        guard scale > 0 else { return .identity }
        let turn = CGAffineTransform(a: t.a / scale, b: t.b / scale, c: t.c / scale, d: t.d / scale, tx: 0, ty: 0)
        return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(turn.inverted())
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
    }

    static func stepRadius(_ annotation: Annotation) -> CGFloat { annotation.fontSize * 0.75 }
    static func highlighterWidth(_ annotation: Annotation) -> CGFloat { annotation.strokeWidth * 4 }

    private static func drawStep(_ annotation: Annotation, in context: CGContext, shadow: (blur: CGFloat, color: CGColor)?) {
        let radius = stepRadius(annotation)
        let circle = CGRect(x: annotation.start.x - radius, y: annotation.start.y - radius, width: radius * 2, height: radius * 2)
        if let shadow { context.setShadow(offset: .zero, blur: shadow.blur, color: shadow.color) }
        context.setFillColor(annotation.color.cgColor)
        context.fillEllipse(in: circle)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(max(1, radius * 0.12))
        context.strokeEllipse(in: circle.insetBy(dx: radius * 0.06, dy: radius * 0.06))

        let label = NSAttributedString(string: "\(annotation.number)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: radius * 1.1, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: annotation.start.x - size.width / 2, y: annotation.start.y - size.height / 2))
    }

    /// A tapered shaft with a filled head, like CleanShot's default arrow.
    static func arrowPath(_ annotation: Annotation) -> CGPath {
        let tail = annotation.start, tip = annotation.end
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length // along
        let nx = -uy, ny = ux // perpendicular

        let width = annotation.strokeWidth
        let headLength = min(length * 0.7, max(width * 4, 12))
        let headWidth = headLength * 0.95
        let base = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)

        func point(_ origin: CGPoint, _ offset: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + nx * offset, y: origin.y + ny * offset)
        }

        let path = CGMutablePath()
        path.move(to: point(tail, width * 0.2))
        path.addLine(to: point(base, width * 0.55))
        path.addLine(to: point(base, headWidth / 2))
        path.addLine(to: tip)
        path.addLine(to: point(base, -headWidth / 2))
        path.addLine(to: point(base, -width * 0.55))
        path.addLine(to: point(tail, -width * 0.2))
        path.closeSubpath()
        return path
    }

    /// Smooths a freehand stroke with quadratic curves through segment midpoints.
    static func freehandPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            path.addLine(to: points.last ?? first)
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    // MARK: - Geometry

    private static func outlinePath(_ annotation: Annotation) -> CGPath? {
        switch annotation.kind {
        case .arrow, .line:
            let path = CGMutablePath()
            path.move(to: annotation.start)
            path.addLine(to: annotation.end)
            return path
        case .rectangle, .redact, .blur, .pixelate: return CGPath(rect: annotation.rect, transform: nil)
        case .ellipse: return CGPath(ellipseIn: annotation.rect, transform: nil)
        case .pen, .highlighter: return freehandPath(annotation.points)
        default: return nil
        }
    }

    /// Bounding box in source pixels, used for selection outlines and hit testing.
    static func bounds(_ annotation: Annotation, orientation: CGAffineTransform = .identity) -> CGRect {
        switch annotation.kind {
        case .text:
            return CGRect(origin: annotation.start, size: textSize(annotation)).applying(upright(about: annotation.start, orientation))
        case .step:
            let r = stepRadius(annotation)
            return CGRect(x: annotation.start.x - r, y: annotation.start.y - r, width: r * 2, height: r * 2)
        case .blur, .pixelate, .redact:
            return annotation.rect
        case .arrow:
            return arrowPath(annotation).boundingBox
        case .highlighter:
            let w = highlighterWidth(annotation)
            return (outlinePath(annotation)?.boundingBox ?? .zero).insetBy(dx: -w / 2, dy: -w / 2)
        default:
            let w = annotation.strokeWidth
            return (outlinePath(annotation)?.boundingBox ?? .zero).insetBy(dx: -w / 2, dy: -w / 2)
        }
    }

    /// `tolerance` is in source pixels. Text and counters are solid, so a point anywhere
    /// on them counts. With `interior`, a point inside a box, redaction or blur/pixelate
    /// region counts too (the Select tool, and what a click selects with any tool);
    /// otherwise only its edge does.
    static func hitTest(
        _ annotation: Annotation, at point: CGPoint, tolerance: CGFloat, interior: Bool = false,
        orientation: CGAffineTransform = .identity
    ) -> Bool {
        let kind = annotation.kind
        if kind == .text || kind == .step || (interior && kind.isBoxed) {
            return bounds(annotation, orientation: orientation).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
        guard let path = outlinePath(annotation) else { return false }
        let stroke: CGFloat = switch kind {
        case .highlighter: highlighterWidth(annotation)
        case .redact, .blur, .pixelate: 0 // Drawn without a stroke.
        default: annotation.strokeWidth
        }
        let width = stroke + tolerance * 2
        return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
    }

    // MARK: - Export

    /// Renders vector annotations into a transparent image of `pixelSize`;
    /// `transform` maps source pixels to image pixels (both top-left origin).
    static func rasterize(_ annotations: [Annotation], pixelSize: CGSize, transform: CGAffineTransform) -> CGImage? {
        let drawable = annotations.filter { !$0.kind.isRegionEffect }
        guard !drawable.isEmpty,
              let context = CGContext(
                  data: nil,
                  width: Int(pixelSize.width.rounded()),
                  height: Int(pixelSize.height.rounded()),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(transform)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for annotation in drawable {
            draw(annotation, in: context, orientation: transform)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
