import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                AnnotationToolbar(model: model)
                Divider()
                canvas
                Divider()
                bottomBar
            }
            // The canvas column absorbs any squeeze; it must never push the sidebar.
            .frame(minWidth: 0, maxWidth: .infinity)
            Divider()
            EditorSidebar(model: model)
                .frame(width: 260)
                .layoutPriority(1)
        }
        .frame(minWidth: 900, minHeight: 500)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                CheckerboardBackground()
                // Pinch to zoom, two-finger scroll to pan, two-finger double-tap for smart zoom.
                CanvasGestureCatcher(model: model)

                if let preview = model.preview {
                    let fit = fitSize(for: preview, in: geometry.size)
                    let _ = model.updateZoomViewport(canvas: geometry.size, fit: fit)
                    let zoom = model.isCropping ? 1 : model.zoom
                    let size = CGSize(width: (fit.width * zoom).rounded(), height: (fit.height * zoom).rounded())
                    ZStack(alignment: .topLeading) {
                        if model.isCropping {
                            cropPreview(preview, size: size)
                            CropOverlay(
                                rect: $model.pendingCrop,
                                aspect: model.normalizedAspect,
                                bounds: model.cropCanvas,
                                size: size,
                                onDragEnded: model.refitCropCanvas
                            )
                        } else {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: size.width, height: size.height)
                            annotationCanvas(displaySize: size)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    .offset(model.isCropping ? .zero : model.pan)
                }

                if let toast = model.toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 16)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // A crop dragged past the canvas, or a zoomed image, mustn't draw over the toolbar or sidebar.
            .clipped()
            // Re-fitting the crop view after a drag eases instead of jumping.
            .animation(.easeOut(duration: 0.2), value: model.cropCanvas)
            .animation(.easeOut(duration: 0.15), value: model.toast)
        }
    }

    /// The crop-mode preview covers more than the visible canvas (so dragging outward
    /// already has pixels); place it against the canvas and show only the image and crop.
    private func cropPreview(_ preview: CGImage, size: CGSize) -> some View {
        let rect = CropOverlay.viewRect(model.previewCropCanvas, bounds: model.cropCanvas, size: size)
        return Image(decorative: preview, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: rect.width, height: rect.height)
            .mask {
                CropOverlay.visibleArea(crop: model.pendingCrop, bounds: model.cropCanvas, size: size)
                    .offsetBy(dx: -rect.minX, dy: -rect.minY)
                    .fill()
            }
            .offset(x: rect.minX, y: rect.minY)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func annotationCanvas(displaySize: CGSize) -> some View {
        let geometry = model.sourceToCanvas()
        let scale = displaySize.width / max(geometry.canvasSize.width, 1)
        let toView = CGAffineTransform(scaleX: scale, y: scale)
        return AnnotationCanvas(
            model: model,
            transform: geometry.transform.concatenating(toView),
            contentRect: geometry.contentRect.applying(toView)
        )
        .frame(width: displaySize.width, height: displaySize.height)
    }

    /// Fit the image in the canvas, but never enlarge past its natural (point) size.
    /// While cropping, the visible crop canvas is fitted instead (it doesn't depend
    /// on the async preview, so the layout stays still while renders land).
    private func fitSize(for preview: CGImage, in available: CGSize) -> CGSize {
        let natural: CGSize
        if model.isCropping {
            let oriented = model.orientedPixelSize
            natural = CGSize(
                width: oriented.width * model.cropCanvas.width / model.screenshot.scale,
                height: oriented.height * model.cropCanvas.height / model.screenshot.scale
            )
        } else {
            let pointsPerPreviewPixel = 1 / (model.previewScale * model.previewShrink * model.screenshot.scale)
            natural = CGSize(
                width: CGFloat(preview.width) * pointsPerPreviewPixel,
                height: CGFloat(preview.height) * pointsPerPreviewPixel
            )
        }
        let inset: CGFloat = 32
        let maxWidth = max(available.width - inset * 2, 50)
        let maxHeight = max(available.height - inset * 2, 50)
        let scale = min(1, maxWidth / natural.width, maxHeight / natural.height)
        return CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        // Pick the richest layout that fits, so the bar never widens the window.
        ViewThatFits(in: .horizontal) {
            if model.isCropping {
                cropBar(segmentedAspect: true, showSize: true)
                cropBar(segmentedAspect: false, showSize: true)
                cropBar(segmentedAspect: false, showSize: false)
            } else {
                editBar(showSize: true)
                editBar(showSize: false)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func cropBar(segmentedAspect: Bool, showSize: Bool) -> some View {
        HStack(spacing: 10) {
            if segmentedAspect {
                Picker("Aspect", selection: $model.cropAspect) {
                    ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                Picker("Aspect", selection: $model.cropAspect) {
                    ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Aspect ratio")
            }

            Picker("Extend", selection: $model.pendingCropExtend) {
                ForEach(CropExtend.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("How to fill a crop that reaches past the image: repeat the edge pixels, or use the most common border color")

            Spacer(minLength: 8)

            if showSize {
                Text(sizeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button("Reset", action: model.resetPendingCrop)
            Button("Cancel", action: model.cancelCrop)
                .keyboardShortcut(.cancelAction)
            Button("Done", action: model.commitCrop)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func editBar(showSize: Bool) -> some View {
        HStack(spacing: 10) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Undo (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)")

            zoomControl

            if showSize {
                Text(sizeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Spacer(minLength: 8)

            Button { model.pin() } label: { Image(systemName: "pin") }
                .help("Pin to screen")
            Button("Copy") { model.copyToPasteboard() }
                .help("Copy to clipboard (⌘C)")
            Button("Save As…") { model.saveAs() }
                .help("Save to a new location (⇧⌘S)")
            Button("Save") { model.save() }
                .help(model.screenshot.fileURL.map { "Save to \($0.lastPathComponent) (⌘S)" } ?? "Save (⌘S)")
                .buttonStyle(.borderedProminent)
        }
    }

    /// Zoom out / percentage (click to fit) / zoom in. Pinch on the trackpad does the same.
    private var zoomControl: some View {
        HStack(spacing: 0) {
            Button { model.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(model.zoom <= EditorModel.zoomRange.lowerBound)
                .help("Zoom Out (⌘-)")
            Button { model.resetZoom() } label: {
                Text(model.zoom > 1.001 ? "\(model.zoomPercent)%" : "Fit")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 44)
            }
            .help("Zoom to Fit (⌘0) — pinch or ⌘-scroll to zoom, two-finger scroll to pan")
            Button { model.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(model.zoom >= EditorModel.zoomRange.upperBound)
                .help("Zoom In (⌘=)")
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private var sizeText: String {
        let size = model.outputPixelSize
        return "\(Int(size.width)) × \(Int(size.height))"
    }
}

// MARK: - Sidebar

private struct EditorSidebar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !model.state.annotations.isEmpty {
                    LayersSection(model: model)
                }

                section("Crop & Rotate") {
                    Button {
                        model.isCropping ? model.commitCrop() : model.beginCrop()
                    } label: {
                        Label(model.isCropping ? "Finish Cropping" : "Crop", systemImage: "crop")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .help("Crop (C)")

                    HStack(spacing: 6) {
                        iconButton("rotate.left", help: "Rotate Left") { model.apply(.rotateLeft) }
                        iconButton("rotate.right", help: "Rotate Right") { model.apply(.rotateRight) }
                        iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip Horizontal") { model.apply(.flipHorizontal) }
                        iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip Vertical") { model.apply(.flipVertical) }
                    }
                }

                section("Adjust") {
                    AdjustmentSlider(model: model, title: "Exposure", keyPath: \.exposure, range: -2...2, neutral: 0)
                    AdjustmentSlider(model: model, title: "Brightness", keyPath: \.brightness, range: -0.5...0.5, neutral: 0)
                    AdjustmentSlider(model: model, title: "Contrast", keyPath: \.contrast, range: 0.5...1.5, neutral: 1)
                    AdjustmentSlider(model: model, title: "Saturation", keyPath: \.saturation, range: 0...2, neutral: 1)
                    AdjustmentSlider(model: model, title: "Vibrance", keyPath: \.vibrance, range: -1...1, neutral: 0)
                    AdjustmentSlider(model: model, title: "Hue", keyPath: \.hue, range: -180...180, neutral: 0, unit: "°")
                    AdjustmentSlider(model: model, title: "Warmth", keyPath: \.warmth, range: -100...100, neutral: 0)

                    Button("Reset Adjustments", action: model.resetAdjustments)
                        .disabled(model.state.adjustments == Adjustments())
                }

                BackdropSection(model: model)

                Button("Revert to Original", role: .destructive, action: model.resetAll)
                    .disabled(model.state.isIdentity)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, minHeight: 20)
        }
        .controlSize(.large)
        .help(help)
    }
}

// MARK: - Layers

/// Annotations as layers, topmost first: click to select, then reorder or delete.
private struct LayersSection: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Layers")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 1) {
                ForEach(model.state.annotations.reversed()) { annotation in
                    row(annotation)
                }
            }

            HStack(spacing: 6) {
                layerButton("square.3.layers.3d.top.filled", help: "Bring to Front (⇧⌘])") { model.moveSelectedAnnotation(.front) }
                layerButton("square.2.layers.3d.top.filled", help: "Bring Forward (⌘])") { model.moveSelectedAnnotation(.forward) }
                layerButton("square.2.layers.3d.bottom.filled", help: "Send Backward (⌘[)") { model.moveSelectedAnnotation(.backward) }
                layerButton("square.3.layers.3d.bottom.filled", help: "Send to Back (⇧⌘[)") { model.moveSelectedAnnotation(.back) }
                layerButton("trash", help: "Delete (⌫)") { model.deleteSelectedAnnotation() }
            }
            .disabled(model.selectedAnnotationID == nil)
        }
    }

    private func row(_ annotation: Annotation) -> some View {
        let isSelected = annotation.id == model.selectedAnnotationID
        return HStack(spacing: 8) {
            Image(systemName: annotation.symbol)
                .frame(width: 16)
                .foregroundStyle(isSelected ? .white : .secondary)
            Text(annotation.layerName)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if !annotation.kind.isRegionEffect {
                Circle()
                    .fill(annotation.color.color)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
            }
        }
        .font(.callout)
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedAnnotationID = isSelected ? nil : annotation.id
        }
    }

    private func layerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, minHeight: 18)
        }
        .help(help)
    }
}

private struct AdjustmentSlider: View {
    @ObservedObject var model: EditorModel
    let title: String
    let keyPath: WritableKeyPath<Adjustments, Double>
    let range: ClosedRange<Double>
    let neutral: Double
    var unit: String = ""

    var body: some View {
        ParameterSlider(
            model: model,
            title: title,
            value: Binding(
                get: { model.state.adjustments[keyPath: keyPath] },
                set: { model.state.adjustments[keyPath: keyPath] = $0 }
            ),
            range: range,
            neutral: neutral,
            format: format
        )
    }

    /// Shown relative to neutral, scaled to −100…100 for unitless sliders.
    private func format(_ v: Double) -> String {
        if !unit.isEmpty || range.upperBound - range.lowerBound > 10 {
            return String(format: "%+.0f%@", v, unit)
        }
        let span = max(range.upperBound - neutral, neutral - range.lowerBound)
        let percent = (v - neutral) / span * 100
        return String(format: "%+.0f", percent)
    }
}

/// A labeled slider whose drags are single undo steps; double-click the label to reset.
private struct ParameterSlider: View {
    @ObservedObject var model: EditorModel
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let neutral: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard value.wrappedValue != neutral else { return }
                model.checkpoint()
                value.wrappedValue = neutral
            }
            .help("Double-click to reset")

            Slider(value: value, in: range) { editing in
                if editing { model.checkpoint() }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Background

private struct BackdropSection: View {
    @ObservedObject var model: EditorModel

    private var backdrop: Backdrop { model.state.backdrop }
    private let swatchColumns = Array(repeating: GridItem(.fixed(30), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Background")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Background", isOn: Binding(
                    get: { backdrop.enabled },
                    set: { enabled in model.updateBackdrop { $0.enabled = enabled } }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }

            if backdrop.enabled {
                LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 8) {
                    Swatch(isSelected: backdrop.fill == .transparent, help: "Transparent") {
                        model.updateBackdrop { $0.fill = .transparent }
                    } content: {
                        TransparencyPattern()
                    }

                    ForEach(GradientPreset.all) { preset in
                        Swatch(isSelected: backdrop.fill == .gradient(id: preset.id), help: preset.id.capitalized) {
                            model.updateBackdrop { $0.fill = .gradient(id: preset.id) }
                        } content: {
                            let points = preset.swiftUIPoints
                            LinearGradient(colors: preset.colors.map(\.color), startPoint: points.start, endPoint: points.end)
                        }
                    }

                    Swatch(isSelected: isImageFill, help: "Choose Image…", action: model.chooseBackgroundImage) {
                        ZStack {
                            Color(nsColor: .controlBackgroundColor)
                            Image(systemName: "photo")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ColorPicker("Solid color", selection: solidColor, supportsOpacity: true)
                    .font(.callout)

                Picker("Aspect", selection: Binding(
                    get: { backdrop.aspect },
                    set: { aspect in model.updateBackdrop { $0.aspect = aspect } }
                )) {
                    ForEach(CanvasAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                slider("Padding", \.padding, 0...240, neutral: 64, format: points)
                slider("Corner Radius", \.cornerRadius, 0...60, neutral: 12, format: points)
                slider("Shadow", \.shadowBlur, 0...120, neutral: 40, format: points)
                slider("Shadow Opacity", \.shadowOpacity, 0...1, neutral: 0.45) { String(format: "%.0f%%", $0 * 100) }
                slider("Shadow Offset", \.shadowOffset, 0...60, neutral: 12, format: points)
            }
        }
    }

    private var isImageFill: Bool {
        if case .image = backdrop.fill { return true }
        return false
    }

    /// Picking a color switches to a solid fill; continuous picker changes after
    /// that merge into one undo step.
    private var solidColor: Binding<Color> {
        Binding(
            get: {
                if case let .solid(color) = backdrop.fill { return color.color }
                return .white
            },
            set: { newColor in
                if case .solid = backdrop.fill {
                    model.state.backdrop.fill = .solid(RGBAColor(newColor))
                } else {
                    model.updateBackdrop { $0.fill = .solid(RGBAColor(newColor)) }
                }
            }
        )
    }

    private func points(_ value: Double) -> String {
        String(format: "%.0f pt", value)
    }

    private func slider(
        _ title: String,
        _ keyPath: WritableKeyPath<Backdrop, Double>,
        _ range: ClosedRange<Double>,
        neutral: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        ParameterSlider(
            model: model,
            title: title,
            value: Binding(
                get: { model.state.backdrop[keyPath: keyPath] },
                set: { model.state.backdrop[keyPath: keyPath] = $0 }
            ),
            range: range,
            neutral: neutral,
            format: format
        )
    }
}

private struct Swatch<Content: View>: View {
    let isSelected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct TransparencyPattern: View {
    var body: some View {
        Canvas { context, size in
            let cell = size.width / 4
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var path = Path()
            for row in 0..<4 {
                for column in 0..<4 where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(Color(white: 0.8)))
        }
    }
}

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.16)))
            var path = Path()
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(Color(white: 0.19)))
        }
    }
}

// MARK: - Trackpad zoom & pan

/// Sits behind the canvas and turns trackpad gestures over it into zoom and pan.
/// A local event monitor sees gestures even when they start over the image or
/// annotation canvas on top.
private struct CanvasGestureCatcher: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> CanvasGestureView { CanvasGestureView(model: model) }
    func updateNSView(_ view: CanvasGestureView, context: Context) {}
}

private final class CanvasGestureView: NSView {
    private let model: EditorModel
    private var monitor: Any?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify]) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.handle(event) }
            }
        } else if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    @MainActor
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, !model.isCropping else { return event }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return event }
        // The image is centered in the canvas, so anchors are relative to its center.
        let anchor = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)

        switch event.type {
        case .magnify:
            model.zoom(by: 1 + event.magnification, around: anchor)
        case .smartMagnify:
            model.toggleZoom(around: anchor)
        case .scrollWheel:
            let precise = event.hasPreciseScrollingDeltas
            if event.modifierFlags.contains(.command) {
                model.zoom(by: 1 + event.scrollingDeltaY * (precise ? 0.01 : 0.1), around: anchor)
            } else {
                let step: CGFloat = precise ? 1 : 10
                model.pan(by: CGSize(width: event.scrollingDeltaX * step, height: event.scrollingDeltaY * step))
            }
        default:
            return event
        }
        return nil
    }
}
