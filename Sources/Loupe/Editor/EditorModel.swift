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
    var crop: CGRect?
    var backdrop = Backdrop()
    var annotations: [Annotation] = []

    /// True when exporting would reproduce the original pixels exactly.
    var isIdentity: Bool {
        adjustments == Adjustments() && orientation.isEmpty && crop == nil && !backdrop.enabled && annotations.isEmpty
    }
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
    @Published private(set) var isCropping = false
    @Published var pendingCrop = EditorModel.fullRect
    @Published var cropAspect: CropAspect = .free {
        didSet { applyAspectToPendingCrop() }
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

    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    init(screenshot: Screenshot) {
        self.screenshot = screenshot
        colorSpace = screenshot.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        fullSource = CIImage(cgImage: screenshot.image)

        let maxPreviewDimension: CGFloat = 2600
        let largest = CGFloat(max(screenshot.image.width, screenshot.image.height))
        if largest > maxPreviewDimension {
            previewScale = maxPreviewDimension / largest
            previewSource = fullSource.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: previewScale,
                kCIInputAspectRatioKey: 1.0,
            ])
        } else {
            previewScale = 1
            previewSource = fullSource
        }

        // Start from the last-used background look, switched off.
        var backdrop = Backdrop.loadLastUsed()
        backdrop.enabled = false
        state.backdrop = backdrop
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
            // A fixed aspect ratio is defined in output pixels, so re-fit it.
            applyAspectToPendingCrop()
        }
    }

    // MARK: - Crop

    func beginCrop() {
        guard !isCropping else { return }
        pendingCrop = state.crop ?? Self.fullRect
        isCropping = true
        scheduleRender()
    }

    func commitCrop() {
        guard isCropping else { return }
        let isFull = pendingCrop.width > 0.999 && pendingCrop.height > 0.999
        let newCrop: CGRect? = isFull ? nil : pendingCrop
        isCropping = false
        if newCrop != state.crop {
            checkpoint()
            state.crop = newCrop
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
        let applyCrop = !isCropping
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
                applyCrop: applyCrop,
                sourceScale: previewScale,
                pixelsPerPoint: pixelsPerPoint,
                includeVectorAnnotations: includeVector
            )
            var image = Self.context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace)
            if applyCrop, let content = image {
                image = state.backdrop.compose(content, pixelsPerPoint: pixelsPerPoint, backgroundImage: backgroundImage)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, latest.isCurrent(token) else { return }
                self.preview = image
            }
        }
    }

    /// The edited image at full resolution.
    func renderFullResolution() -> CGImage? {
        if state.isIdentity { return screenshot.image }
        let output = Self.render(
            fullSource,
            state: state,
            applyCrop: true,
            sourceScale: 1,
            pixelsPerPoint: screenshot.scale,
            includeVectorAnnotations: true
        )
        guard let content = Self.context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }
        return state.backdrop.compose(content, pixelsPerPoint: screenshot.scale, backgroundImage: currentBackgroundImage)
    }

    /// - sourceScale: `source` pixels per full-resolution pixel (annotations are in full-res pixels).
    /// - pixelsPerPoint: `source` pixels per screen point, for sizing blur/pixelate.
    nonisolated static func render(
        _ source: CIImage,
        state: EditState,
        applyCrop: Bool,
        sourceScale: CGFloat,
        pixelsPerPoint: CGFloat,
        includeVectorAnnotations: Bool
    ) -> CIImage {
        var image = source
        let a = state.adjustments

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
        image = image.cropped(to: source.extent)
        image = applyAnnotations(
            state.annotations,
            to: image,
            sourceScale: sourceScale,
            pixelsPerPoint: pixelsPerPoint,
            includeVector: includeVectorAnnotations
        )

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

        if applyCrop, let crop = state.crop {
            let e = image.extent
            let rect = CGRect(
                x: e.minX + crop.minX * e.width,
                y: e.minY + (1 - crop.maxY) * e.height,
                width: crop.width * e.width,
                height: crop.height * e.height
            ).integral
            image = image.cropped(to: rect).movedToOrigin()
        }
        return image
    }

    /// Blur/pixelate regions are Core Image effects on the pixels underneath;
    /// everything else is rasterized with AnnotationRenderer and composited on top.
    nonisolated private static func applyAnnotations(
        _ annotations: [Annotation],
        to input: CIImage,
        sourceScale: CGFloat,
        pixelsPerPoint: CGFloat,
        includeVector: Bool
    ) -> CIImage {
        guard !annotations.isEmpty else { return input }
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

        if includeVector,
           let overlay = AnnotationRenderer.rasterize(annotations, pixelSize: extent.size, scale: sourceScale) {
            let placed = CIImage(cgImage: overlay).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            image = placed.composited(over: image)
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
        var transform = CGAffineTransform.identity
        var w = CGFloat(screenshot.image.width), h = CGFloat(screenshot.image.height)

        for op in state.orientation {
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

        if let crop = state.crop {
            transform = transform.concatenating(CGAffineTransform(translationX: -crop.minX * w, y: -crop.minY * h))
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
