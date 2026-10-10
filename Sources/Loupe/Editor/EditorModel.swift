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

    /// True when exporting would reproduce the original pixels exactly.
    var isIdentity: Bool {
        adjustments == Adjustments() && orientation.isEmpty && crop == nil && !backdrop.enabled
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
        let state = self.state
        let applyCrop = !isCropping
        let source = previewSource
        let colorSpace = self.colorSpace
        let latest = latestRender
        let backgroundImage = currentBackgroundImage
        let pixelsPerPoint = screenshot.scale * previewScale

        renderQueue.async {
            // Skip frames that were superseded while a slider was moving.
            guard latest.isCurrent(token) else { return }
            let output = Self.render(source, state: state, applyCrop: applyCrop)
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
        let output = Self.render(fullSource, state: state, applyCrop: true)
        guard let content = Self.context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }
        return state.backdrop.compose(content, pixelsPerPoint: screenshot.scale, backgroundImage: currentBackgroundImage)
    }

    nonisolated static func render(_ source: CIImage, state: EditState, applyCrop: Bool) -> CIImage {
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

    // MARK: - Output

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
