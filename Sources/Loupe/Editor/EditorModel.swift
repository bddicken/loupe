import AppKit
import CoreImage

enum OrientationOp: Equatable {
    case rotateLeft, rotateRight, flipHorizontal, flipVertical

    var swapsAxes: Bool { self == .rotateLeft || self == .rotateRight }

    /// Maps a normalized rect (top-left origin) through this operation so a
    /// crop stays on the same content when the image is rotated or flipped.
    func transform(_ r: CGRect) -> CGRect {
        switch self {
        case .rotateRight: CGRect(x: 1 - r.minY - r.height, y: r.minX, width: r.height, height: r.width)
        case .rotateLeft: CGRect(x: r.minY, y: 1 - r.minX - r.width, width: r.height, height: r.width)
        case .flipHorizontal: CGRect(x: 1 - r.minX - r.width, y: r.minY, width: r.width, height: r.height)
        case .flipVertical: CGRect(x: r.minX, y: 1 - r.minY - r.height, width: r.width, height: r.height)
        }
    }
}

struct Adjustments: Equatable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var vibrance: Double = 0
    var hue: Double = 0 // degrees
    var warmth: Double = 0 // -100 … 100
}

/// Everything about an edit, as a value — so undo is just a stack of these.
struct EditState: Equatable {
    var adjustments = Adjustments()
    var orientation: [OrientationOp] = []
    /// Normalized crop (top-left origin) in the oriented image's space. nil = uncropped.
    /// It may reach past 0…1; `cropExtend` says how the area past the image is filled.
    var crop: CGRect?
    var cropExtend: CropExtend = .edgePixels
    var backdrop = Backdrop()
    var annotations: [Annotation] = []

    /// True when exporting would reproduce the original pixels exactly.
    var isIdentity: Bool {
        adjustments == Adjustments() && orientation.isEmpty && crop == nil && !backdrop.enabled && annotations.isEmpty
    }
}

/// How a crop that reaches past the image's edges fills the extra area.
enum CropExtend: String, CaseIterable, Identifiable {
    /// Repeat each edge pixel outward.
    case edgePixels = "Edge Pixels"
    /// One solid color: the most common color along the image's border.
    case commonColor = "Common Color"

    var id: String { rawValue }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free"
    case original = "Original"
    case square = "1:1"
    case fourThree = "4:3"
    case threeTwo = "3:2"
    case sixteenNine = "16:9"

    var id: String { rawValue }

    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: original.width / max(original.height, 1)
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .threeTwo: 3.0 / 2.0
        case .sixteenNine: 16.0 / 9.0
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    static let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    let screenshot: Screenshot

    @Published var state = EditState() {
        didSet {
            guard state != oldValue else { return }
            if state.backdrop != oldValue.backdrop {
                loadBackgroundImageIfNeeded()
                state.backdrop.saveAsLastUsed()
            }
            scheduleRender()
        }
    }
    @Published private(set) var preview: CGImage?
    /// Preview pixels per `previewSource` pixel: below 1 when a crop reaching far
    /// past the image was shrunk to keep the preview a manageable size.
    @Published private(set) var previewShrink: CGFloat = 1
    /// The `cropCanvas` the current preview was rendered with, so the crop overlay
    /// lines up with the image even before a re-render lands.
    @Published private(set) var previewCropCanvas = EditorModel.fullRect
    @Published private(set) var isCropping = false
    @Published var pendingCrop = EditorModel.fullRect
    /// While cropping, the area shown (normalized, like `pendingCrop`): the image
    /// and the crop, plus room around them to keep dragging outward.
    @Published private(set) var cropCanvas = EditorModel.fullRect
    @Published var cropAspect: CropAspect = .free {
        didSet { applyAspectToPendingCrop() }
    }
    @Published var pendingCropExtend: CropExtend = .edgePixels {
        didSet { if pendingCropExtend != oldValue { scheduleRender() } }
    }
    @Published private(set) var savedState = EditState()
    @Published var toast: String?

    // Annotation tool settings.
    @Published var tool: AnnotationTool = .arrow
    @Published private(set) var annotationColor = RGBAColor(hex: 0xFF3B30)
    /// Stroke width in points; text and counters scale from it.
    @Published private(set) var annotationSize: Double = 4
    @Published var selectedAnnotationID: UUID? {
        didSet {
            // The toolbar reflects the selected layer's color and size.
            guard selectedAnnotationID != oldValue, let selected = selectedAnnotation else { return }
            annotationColor = selected.color
            if selected.kind != .text, selected.kind != .step {
                annotationSize = Double(selected.strokeWidth / screenshot.scale)
            }
        }
    }
    /// A blur/pixelate region being dragged out; rendered live but not yet in `state`.
    @Published var regionDraft: Annotation? {
        didSet { if regionDraft != oldValue { scheduleRender() } }
    }

    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []

    private let fullSource: CIImage
    private let previewSource: CIImage
    /// previewSource pixels per fullSource pixel (≤ 1).
    let previewScale: CGFloat
    private let colorSpace: CGColorSpace
    private let renderQueue = DispatchQueue(label: "dev.loupe.render", qos: .userInitiated)
    private let latestRender = RenderToken()
    private var toastTask: Task<Void, Never>?
    private var backgroundImages: [String: CGImage] = [:]
    /// A 1×1 image of the most common border pixel, for `CropExtend.commonColor`.
    private lazy var commonEdgePixel: CIImage? = Self.mostCommonEdgePixel(of: screenshot.image)
        .map { fullSource.cropped(to: CGRect(x: $0.x, y: $0.y, width: 1, height: 1)) }

    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    init(screenshot: Screenshot) {
        self.screenshot = screenshot
        colorSpace = screenshot.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        fullSource = CIImage(cgImage: screenshot.image)

        let maxPreviewDimension: CGFloat = 2600
        let largest = CGFloat(max(screenshot.image.width, screenshot.image.height))
        if largest > maxPreviewDimension {
            previewScale = maxPreviewDimension / largest
            let scaled = fullSource.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: previewScale,
                kCIInputAspectRatioKey: 1.0,
            ])
            // Drop the partially covered edge pixels so extending the edges past a crop stays opaque.
            let e = scaled.extent
            previewSource = scaled.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width.rounded(.down), height: e.height.rounded(.down)))
        } else {
            previewScale = 1
            previewSource = fullSource
        }

        // Start from the last-used background look, switched off.
        var backdrop = Backdrop.loadLastUsed()
        backdrop.enabled = false
        state.backdrop = backdrop
        state.cropExtend = Preferences.cropExtend
        savedState = state
        loadBackgroundImageIfNeeded()
        scheduleRender()
    }

    // MARK: - Derived

    var isDirty: Bool { state != savedState }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Pixel size of the full-resolution image after orientation (before crop).
    var orientedPixelSize: CGSize {
        let w = CGFloat(screenshot.image.width), h = CGFloat(screenshot.image.height)
        let swaps = state.orientation.filter(\.swapsAxes).count % 2 == 1
        return swaps ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Pixel size of what will be exported.
    var outputPixelSize: CGSize {
        let oriented = orientedPixelSize
        let crop = isCropping ? pendingCrop : (state.crop ?? Self.fullRect)
        let content = CGSize(width: (oriented.width * crop.width).rounded(), height: (oriented.height * crop.height).rounded())
        if isCropping { return content }
        return state.backdrop.canvasSize(forContent: content, pixelsPerPoint: screenshot.scale)
    }

    // MARK: - Undo

    /// Call before a change that should be undoable as one step.
    func checkpoint() {
        undoStack.append(state)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard !isCropping, let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
    }

    func redo() {
        guard !isCropping, let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
    }

    // MARK: - Edits

    func resetAdjustments() {
        guard state.adjustments != Adjustments() else { return }
        checkpoint()
        state.adjustments = Adjustments()
    }

    func resetAll() {
        guard !state.isIdentity else { return }
        if isCropping { cancelCrop() }
        checkpoint()
        // Keep the background settings around (just disabled) so re-enabling restores them.
        var reset = EditState()
        reset.backdrop = state.backdrop
        reset.backdrop.enabled = false
        state = reset
    }

    // MARK: - Backdrop

    /// Updates backdrop settings as one undoable step (use `checkpoint()` +
    /// direct mutation for continuous changes like sliders).
    func updateBackdrop(_ change: (inout Backdrop) -> Void) {
        var backdrop = state.backdrop
        change(&backdrop)
        guard backdrop != state.backdrop else { return }
        checkpoint()
        state.backdrop = backdrop
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        panel.message = "Choose a background image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateBackdrop {
            $0.fill = .image(path: url.path)
            $0.enabled = true
        }
    }

    private var currentBackgroundImage: CGImage? {
        guard case let .image(path) = state.backdrop.fill else { return nil }
        return backgroundImages[path]
    }

    private func loadBackgroundImageIfNeeded() {
        guard case let .image(path) = state.backdrop.fill, backgroundImages[path] == nil else { return }
        if let image = Backdrop.loadBackgroundImage(path: path) {
            backgroundImages = [path: image] // Only keep the current one.
        }
    }

    func apply(_ op: OrientationOp) {
        checkpoint()
        state.orientation.append(op)
        state.crop = state.crop.map(op.transform)
        if isCropping {
            pendingCrop = op.transform(pendingCrop)
            cropCanvas = op.transform(cropCanvas)
            // A fixed aspect ratio is defined in output pixels, so re-fit it.
            applyAspectToPendingCrop()
        }
    }

    // MARK: - Crop

    func beginCrop() {
        guard !isCropping else { return }
        pendingCrop = state.crop ?? Self.fullRect
        cropCanvas = makeCropCanvas(around: pendingCrop)
        pendingCropExtend = state.cropExtend
        isCropping = true
        scheduleRender()
    }

    func commitCrop() {
        guard isCropping else { return }
        let r = pendingCrop
        let isFull = abs(r.minX) < 0.001 && abs(r.minY) < 0.001 && abs(r.maxX - 1) < 0.001 && abs(r.maxY - 1) < 0.001
        let newCrop: CGRect? = isFull ? nil : pendingCrop
        isCropping = false
        Preferences.cropExtend = pendingCropExtend
        if newCrop != state.crop || pendingCropExtend != state.cropExtend {
            checkpoint()
            state.crop = newCrop
            state.cropExtend = pendingCropExtend
        } else {
            scheduleRender()
        }
    }

    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        scheduleRender()
    }

    func resetPendingCrop() {
        pendingCrop = Self.fullRect
        applyAspectToPendingCrop()
        refitCropCanvas()
    }

    /// Zooms the crop view in or out to fit the crop (call when a drag ends),
    /// so there is always room to drag it further.
    func refitCropCanvas() {
        guard isCropping else { return }
        let canvas = makeCropCanvas(around: pendingCrop)
        guard canvas != cropCanvas else { return }
        cropCanvas = canvas
        scheduleRender()
    }

    /// The image and `crop`, padded on every side.
    private func makeCropCanvas(around crop: CGRect) -> CGRect {
        let size = orientedPixelSize
        let content = Self.fullRect.union(crop)
        let pad = max(max(content.width * size.width, content.height * size.height) * 0.15, 48 * screenshot.scale)
        return content.insetBy(dx: -pad / size.width, dy: -pad / size.height)
    }

    /// Width/height ratio in normalized crop space for the chosen aspect, if any.
    var normalizedAspect: CGFloat? {
        let size = orientedPixelSize
        guard let ratio = cropAspect.ratio(original: size) else { return nil }
        return ratio * size.height / size.width
    }

    private func applyAspectToPendingCrop() {
        guard isCropping, let aspect = normalizedAspect else { return }
        var r = pendingCrop
        if r.width / r.height > aspect {
            let width = r.height * aspect
            r.origin.x += (r.width - width) / 2
            r.size.width = width
        } else {
            let height = r.width / aspect
            r.origin.y += (r.height - height) / 2
            r.size.height = height
        }
        pendingCrop = r
    }

    // MARK: - Rendering

    private func scheduleRender() {
        let token = latestRender.next()
        var state = self.state
        if let regionDraft { state.annotations.append(regionDraft) }
        let isCropping = self.isCropping
        if isCropping { state.cropExtend = pendingCropExtend }
        let fillPixel = state.cropExtend == .commonColor ? commonEdgePixel : nil
        // While cropping, show the whole canvas so the crop can be dragged past the edges.
        let crop = isCropping ? cropCanvas : state.crop
        let source = previewSource
        let colorSpace = self.colorSpace
        let latest = latestRender
        let backgroundImage = currentBackgroundImage
        let pixelsPerPoint = screenshot.scale * previewScale
        let previewScale = self.previewScale
        // The live canvas draws vector annotations on top of the preview,
        // except while cropping (when the canvas is hidden).
        let includeVector = isCropping

        renderQueue.async {
            // Skip frames that were superseded while a slider was moving.
            guard latest.isCurrent(token) else { return }
            let output = Self.render(
                source,
                state: state,
                crop: crop,
                fillPixel: fillPixel,
                sourceScale: previewScale,
                pixelsPerPoint: pixelsPerPoint,
                includeVectorAnnotations: includeVector
            )
            // A crop reaching far past the image can be huge; the preview only needs to fill the window.
            let maxDimension: CGFloat = 4096
            let largest = max(output.extent.width, output.extent.height)
            let shrink = largest > maxDimension ? maxDimension / largest : 1
            let shrunk = shrink < 1 ? output.transformed(by: CGAffineTransform(scaleX: shrink, y: shrink)) : output
            var image = Self.context.createCGImage(shrunk, from: shrunk.extent.integral, format: .RGBA8, colorSpace: colorSpace)
            if !isCropping, let content = image {
                image = state.backdrop.compose(content, pixelsPerPoint: pixelsPerPoint * shrink, backgroundImage: backgroundImage)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, latest.isCurrent(token) else { return }
                self.preview = image
                self.previewShrink = shrink
                if let crop, isCropping { self.previewCropCanvas = crop }
            }
        }
    }

    /// The edited image at full resolution.
    func renderFullResolution() -> CGImage? {
        if state.isIdentity { return screenshot.image }
        let output = Self.render(
            fullSource,
            state: state,
            crop: state.crop,
            fillPixel: state.cropExtend == .commonColor ? commonEdgePixel : nil,
            sourceScale: 1,
            pixelsPerPoint: screenshot.scale,
            includeVectorAnnotations: true
        )
        guard let content = Self.context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }
        return state.backdrop.compose(content, pixelsPerPoint: screenshot.scale, backgroundImage: currentBackgroundImage)
    }

    /// - crop: normalized rect in the oriented image; parts past its edges repeat the edge pixels,
    ///   or are filled with `fillPixel` (a 1×1 source pixel, adjusted like the image) when given.
    /// - sourceScale: `source` pixels per full-resolution pixel (annotations are in full-res pixels).
    /// - pixelsPerPoint: `source` pixels per screen point, for sizing blur/pixelate.
    nonisolated static func render(
        _ source: CIImage,
        state: EditState,
        crop: CGRect?,
        fillPixel: CIImage?,
        sourceScale: CGFloat,
        pixelsPerPoint: CGFloat,
        includeVectorAnnotations: Bool
    ) -> CIImage {
        var image = applyAdjustments(state.adjustments, to: source).cropped(to: source.extent)
        image = applyRegionEffects(state.annotations, to: image, sourceScale: sourceScale, pixelsPerPoint: pixelsPerPoint)

        for op in state.orientation {
            let transform: CGAffineTransform
            switch op {
            // Core Image is y-up, so a visual clockwise turn is a negative angle.
            case .rotateRight: transform = CGAffineTransform(rotationAngle: -.pi / 2)
            case .rotateLeft: transform = CGAffineTransform(rotationAngle: .pi / 2)
            case .flipHorizontal: transform = CGAffineTransform(scaleX: -1, y: 1)
            case .flipVertical: transform = CGAffineTransform(scaleX: 1, y: -1)
            }
            image = image.transformed(by: transform).movedToOrigin()
        }

        // Source pixels (top-left origin) → output pixels (top-left origin), for vector annotations.
        var toOutput = CGAffineTransform(scaleX: sourceScale, y: sourceScale)
            .concatenating(orientationTransform(size: source.extent.size, orientation: state.orientation).transform)

        if let crop {
            // Whole pixels, top-left origin, rounded the same way as sourceToCanvas.
            let e = image.extent
            let left = (crop.minX * e.width).rounded(), top = (crop.minY * e.height).rounded()
            let width = (crop.width * e.width).rounded(), height = (crop.height * e.height).rounded()
            let rect = CGRect(x: e.minX + left, y: e.maxY - top - height, width: width, height: height)
            // Fill any part of the crop past the image: repeat the edge pixels outward, or use one solid color.
            let extended = if let fillPixel {
                image.composited(over: applyAdjustments(state.adjustments, to: fillPixel).cropped(to: fillPixel.extent).clampedToExtent())
            } else {
                image.clampedToExtent()
            }
            image = extended.cropped(to: rect).movedToOrigin()
            toOutput = toOutput.concatenating(CGAffineTransform(translationX: -left, y: -top))
        }

        // Drawn after cropping so annotations placed past the image's edges aren't clipped.
        if includeVectorAnnotations,
           let overlay = AnnotationRenderer.rasterize(state.annotations, pixelSize: image.extent.size, transform: toOutput) {
            image = CIImage(cgImage: overlay).composited(over: image)
        }
        return image
    }

    nonisolated private static func applyAdjustments(_ a: Adjustments, to input: CIImage) -> CIImage {
        var image = input
        if a.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
        }
        if a.warmth != 0 {
            // Claiming the source's white point is bluer than it is warms the image.
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + a.warmth * 35, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: a.brightness,
                kCIInputContrastKey: a.contrast,
                kCIInputSaturationKey: a.saturation,
            ])
        }
        if a.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance])
        }
        if a.hue != 0 {
            image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: a.hue * .pi / 180])
        }
        return image
    }

    /// Blur/pixelate regions are Core Image effects on the pixels underneath.
    nonisolated private static func applyRegionEffects(
        _ annotations: [Annotation],
        to input: CIImage,
        sourceScale: CGFloat,
        pixelsPerPoint: CGFloat
    ) -> CIImage {
        let extent = input.extent
        var image = input

        for annotation in annotations where annotation.kind.isRegionEffect {
            let r = annotation.rect
            let region = CGRect(
                x: extent.minX + r.minX * sourceScale,
                y: extent.maxY - r.maxY * sourceScale, // flip to Core Image's y-up space
                width: r.width * sourceScale,
                height: r.height * sourceScale
            ).intersection(extent)
            guard !region.isNull, region.width >= 1, region.height >= 1 else { continue }

            let effect: CIImage
            if annotation.kind == .blur {
                effect = image.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12 * pixelsPerPoint])
            } else {
                effect = image.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: max(4, 10 * pixelsPerPoint),
                    kCIInputCenterKey: CIVector(x: region.minX, y: region.minY),
                ])
            }
            image = effect.cropped(to: region).composited(over: image)
        }
        return image
    }

    // MARK: - Annotations

    func newAnnotation(_ kind: Annotation.Kind, points: [CGPoint]) -> Annotation {
        let pixelsPerPoint = screenshot.scale
        var annotation = Annotation(
            kind: kind,
            points: points,
            color: annotationColor,
            strokeWidth: annotationSize * pixelsPerPoint,
            fontSize: (10 + annotationSize * 4) * pixelsPerPoint
        )
        if kind == .step {
            annotation.number = (state.annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1
        }
        return annotation
    }

    func addAnnotation(_ annotation: Annotation) {
        checkpoint()
        state.annotations.append(annotation)
        selectedAnnotationID = annotation.id
    }

    func updateAnnotation(_ id: UUID, checkpoint shouldCheckpoint: Bool, _ change: (inout Annotation) -> Void) {
        guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        var annotation = state.annotations[index]
        change(&annotation)
        guard annotation != state.annotations[index] else { return }
        if shouldCheckpoint { checkpoint() }
        state.annotations[index] = annotation
    }

    /// Not undoable on its own — call `checkpoint()` once before a drag.
    func moveAnnotation(_ id: UUID, dx: CGFloat, dy: CGFloat) {
        guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        state.annotations[index] = state.annotations[index].offsetBy(dx: dx, dy: dy)
    }

    func removeAnnotation(_ id: UUID) {
        guard state.annotations.contains(where: { $0.id == id }) else { return }
        checkpoint()
        state.annotations.removeAll { $0.id == id }
        if selectedAnnotationID == id { selectedAnnotationID = nil }
    }

    func deleteSelectedAnnotation() {
        if let id = selectedAnnotationID { removeAnnotation(id) }
    }

    enum LayerMove { case forward, backward, front, back }

    /// Changes the selected annotation's stacking order (later = on top).
    func moveSelectedAnnotation(_ move: LayerMove) {
        guard let id = selectedAnnotationID,
              let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        let last = state.annotations.count - 1
        let target = switch move {
        case .forward: min(index + 1, last)
        case .backward: max(index - 1, 0)
        case .front: last
        case .back: 0
        }
        guard target != index else { return }
        checkpoint()
        let annotation = state.annotations.remove(at: index)
        state.annotations.insert(annotation, at: target)
    }

    var selectedAnnotation: Annotation? {
        state.annotations.first { $0.id == selectedAnnotationID }
    }

    /// Sets the drawing color, and recolors the selected annotation.
    func setAnnotationColor(_ color: RGBAColor, checkpoint shouldCheckpoint: Bool = true) {
        annotationColor = color
        if let id = selectedAnnotationID {
            updateAnnotation(id, checkpoint: shouldCheckpoint) { $0.color = color }
        }
    }

    /// Sets the drawing size, and resizes the selected annotation.
    func setAnnotationSize(_ size: Double, checkpoint shouldCheckpoint: Bool) {
        annotationSize = size
        if let id = selectedAnnotationID {
            let pixelsPerPoint = screenshot.scale
            updateAnnotation(id, checkpoint: shouldCheckpoint) {
                $0.strokeWidth = size * pixelsPerPoint
                $0.fontSize = (10 + size * 4) * pixelsPerPoint
            }
        }
    }

    // MARK: - Geometry

    /// Maps source pixels (top-left origin) to full-resolution canvas pixels
    /// (top-left origin): orientation, then crop, then backdrop padding.
    /// Also returns the canvas size and where the screenshot sits in it.
    func sourceToCanvas() -> (transform: CGAffineTransform, canvasSize: CGSize, contentRect: CGRect) {
        let source = CGSize(width: screenshot.image.width, height: screenshot.image.height)
        var (transform, oriented) = Self.orientationTransform(size: source, orientation: state.orientation)
        var w = oriented.width, h = oriented.height

        if let crop = state.crop {
            transform = transform.concatenating(CGAffineTransform(translationX: -(crop.minX * w).rounded(), y: -(crop.minY * h).rounded()))
            w = (crop.width * w).rounded()
            h = (crop.height * h).rounded()
        }

        let content = CGSize(width: w, height: h)
        let canvas = state.backdrop.canvasSize(forContent: content, pixelsPerPoint: screenshot.scale)
        // Same placement as Backdrop.compose (which works y-up).
        let x = ((canvas.width - w) / 2).rounded()
        let yUp = ((canvas.height - h) / 2).rounded()
        let y = canvas.height - yUp - h
        transform = transform.concatenating(CGAffineTransform(translationX: x, y: y))
        return (transform, canvas, CGRect(x: x, y: y, width: w, height: h))
    }

    /// Where (in Core Image's y-up pixel coordinates) the most common color on the
    /// image's 1px border first appears. Exact matches, not an average, so a solid
    /// background wins even when the border also crosses other content.
    nonisolated static func mostCommonEdgePixel(of image: CGImage) -> CGPoint? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let context = CGContext(
                  data: nil, width: w, height: 1, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt32.self, capacity: w)

        var counts: [UInt32: Int] = [:]
        var firstSeen: [UInt32: CGPoint] = [:]
        // Read one row or column at a time (top-left origin) so a large image is never fully decoded.
        func scan(_ strip: CGRect, _ point: (Int) -> CGPoint) {
            guard let cropped = image.cropping(to: strip) else { return }
            let length = Int(max(strip.width, strip.height))
            context.clear(CGRect(x: 0, y: 0, width: w, height: 1))
            if strip.width >= strip.height {
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: length, height: 1))
            } else {
                // Lay the column out horizontally: its top pixel at x = 0.
                context.saveGState()
                context.translateBy(x: CGFloat(length), y: 0)
                context.rotate(by: .pi / 2)
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: length))
                context.restoreGState()
            }
            for i in 0..<length {
                let pixel = pixels[i]
                counts[pixel, default: 0] += 1
                if firstSeen[pixel] == nil { firstSeen[pixel] = point(i) }
            }
        }
        scan(CGRect(x: 0, y: 0, width: w, height: 1)) { CGPoint(x: $0, y: h - 1) }
        scan(CGRect(x: 0, y: h - 1, width: w, height: 1)) { CGPoint(x: $0, y: 0) }
        scan(CGRect(x: 0, y: 0, width: 1, height: h)) { CGPoint(x: 0, y: h - 1 - $0) }
        scan(CGRect(x: w - 1, y: 0, width: 1, height: h)) { CGPoint(x: w - 1, y: h - 1 - $0) }
        return counts.max { $0.value < $1.value }.flatMap { firstSeen[$0.key] }
    }

    /// Maps an image of `size` (top-left origin) through `orientation`; also returns the oriented size.
    nonisolated static func orientationTransform(size: CGSize, orientation: [OrientationOp]) -> (transform: CGAffineTransform, size: CGSize) {
        var transform = CGAffineTransform.identity
        var w = size.width, h = size.height
        for op in orientation {
            // x' = a·x + c·y + tx,  y' = b·x + d·y + ty
            let step: CGAffineTransform = switch op {
            case .rotateRight: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
            case .rotateLeft: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
            case .flipHorizontal: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
            case .flipVertical: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
            }
            transform = transform.concatenating(step)
            if op.swapsAxes { swap(&w, &h) }
        }
        return (transform, CGSize(width: w, height: h))
    }

    // MARK: - Output

    func pin() {
        guard let image = renderFullResolution() else { return }
        PinManager.shared.pin(Screenshot(image: image, scale: screenshot.scale))
    }

    func copyToPasteboard() {
        guard let image = renderFullResolution() else { return }
        ImageExport.copyToPasteboard(image, scale: screenshot.scale)
        showToast("Copied to clipboard")
    }

    /// Saves over the screenshot's file (or a new file in the save folder).
    @discardableResult
    func save() -> Bool {
        guard let image = renderFullResolution() else { return false }
        let url = screenshot.fileURL ?? ImageExport.newFileURL(for: screenshot.date)
        do {
            try ImageExport.write(image, scale: screenshot.scale, to: url)
            screenshot.fileURL = url
            savedState = state
            showToast("Saved \(url.lastPathComponent)")
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    @discardableResult
    func saveAs() -> Bool {
        guard let image = renderFullResolution() else { return false }
        let name = screenshot.fileURL?.lastPathComponent
            ?? ImageExport.defaultFileName(for: screenshot.date, format: Preferences.imageFormat)
        guard let url = ImageExport.runSavePanel(for: image, scale: screenshot.scale, suggestedName: name) else { return false }
        screenshot.fileURL = url
        savedState = state
        showToast("Saved \(url.lastPathComponent)")
        return true
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

private extension CIImage {
    func movedToOrigin() -> CIImage {
        transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}

/// Monotonic counter shared with the render queue to drop stale frames.
private final class RenderToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == token
    }
}
