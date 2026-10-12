import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel

    static let backgroundPanelWidth: CGFloat = 260

    var body: some View {
        HStack(spacing: 0) {
            // The background panel steps aside while cropping (it doesn't apply there).
            if model.showsBackgroundPanel && !model.isCropping {
                BackgroundPanel(model: model)
                    .frame(width: EditorView.backgroundPanelWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
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
        .animation(.easeInOut(duration: 0.2), value: model.showsBackgroundPanel)
        // A fixed minimum: panels and modes take space from the canvas instead of resizing the window.
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
                    let layout = canvasLayout(for: preview, in: geometry.size)
                    let _ = model.updateZoomViewport(canvas: geometry.size, fit: layout.fit, scale: layout.scale)
                    let zoom = model.zoom
                    let size = CGSize(width: (layout.fit.width * zoom).rounded(), height: (layout.fit.height * zoom).rounded())
                    Group {
                        if model.isCropping {
                            ZStack(alignment: .topLeading) {
                                cropPreview(preview, size: size)
                                CropOverlay(
                                    rect: $model.pendingCrop,
                                    aspect: model.normalizedAspect,
                                    bounds: model.cropCanvas,
                                    size: size
                                )
                            }
                            .frame(width: size.width, height: size.height)
                        } else {
                            editedImage(preview, size: size, scale: layout.scale * zoom)
                        }
                    }
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    .offset(model.pan)
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

    /// The edited image with its background drawn live: the gradient, padding,
    /// rounded corners and shadow are view layers, so dragging a background slider
    /// is instant and the image, background and drawings always move together.
    /// (Export renders the same look at full resolution with Backdrop.compose.)
    private func editedImage(_ preview: CGImage, size: CGSize, scale: CGFloat) -> some View {
        let content = contentNaturalSize(of: preview)
        let contentSize = CGSize(width: (content.width * scale).rounded(), height: (content.height * scale).rounded())
        let backdrop = model.state.backdrop
        let radius = backdrop.enabled ? min(backdrop.cornerRadius * scale, min(contentSize.width, contentSize.height) / 2) : 0
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        return ZStack {
            if backdrop.enabled {
                BackdropFillView(backdrop: backdrop, image: model.backgroundImage, pixelsPerPoint: scale)
                    .equatable()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                // Like export: the shadow is cast by the rounded shape (not the image's own
                // transparency), never shows under the image, and stops at the canvas edge.
                shape
                    .fill(.black)
                    .frame(width: contentSize.width, height: contentSize.height)
                    .shadow(
                        color: .black.opacity(backdrop.shadowOpacity),
                        // Core Graphics' shadow blur is roughly twice SwiftUI's radius.
                        radius: backdrop.shadowBlur * scale / 2,
                        x: 0,
                        y: backdrop.shadowOffset * scale
                    )
                    .overlay(shape.fill(.black).frame(width: contentSize.width, height: contentSize.height).blendMode(.destinationOut))
                    .compositingGroup()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .opacity(backdrop.shadowOpacity > 0 && (backdrop.shadowBlur > 0 || backdrop.shadowOffset > 0) ? 1 : 0)
            }
            Image(decorative: preview, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: contentSize.width, height: contentSize.height)
                .clipShape(shape)
            annotationCanvas(contentSize: contentSize)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Drawings over the image. Positioned with the state the preview was rendered
    /// from, so after a rotate or crop they move in the same frame as the image.
    private func annotationCanvas(contentSize: CGSize) -> some View {
        let mapping = model.sourceToContent(for: model.previewState)
        let scale = contentSize.width / max(mapping.size.width, 1)
        // A margin keeps selection handles on the image's edges fully visible.
        let margin: CGFloat = 16
        let toView = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: margin, y: margin))
        return AnnotationCanvas(
            model: model,
            transform: mapping.transform.concatenating(toView),
            contentRect: CGRect(x: margin, y: margin, width: contentSize.width, height: contentSize.height)
        )
        .frame(width: contentSize.width + margin * 2, height: contentSize.height + margin * 2)
    }

    /// The edited image's size in points at 100% (the preview may be downscaled).
    private func contentNaturalSize(of preview: CGImage) -> CGSize {
        let pointsPerPreviewPixel = 1 / (model.previewScale * model.previewShrink * model.screenshot.scale)
        return CGSize(width: CGFloat(preview.width) * pointsPerPreviewPixel, height: CGFloat(preview.height) * pointsPerPreviewPixel)
    }

    /// Fits what's shown in the canvas (the image plus its background, or while
    /// cropping, the crop canvas) without enlarging past its natural size.
    /// Returns the fitted size and the fitted points per image point.
    private func canvasLayout(for preview: CGImage, in available: CGSize) -> (fit: CGSize, scale: CGFloat) {
        let natural: CGSize
        if model.isCropping {
            // Independent of the async preview, so the layout stays still while renders land.
            let oriented = model.orientedPixelSize
            natural = CGSize(
                width: oriented.width * model.cropCanvas.width / model.screenshot.scale,
                height: oriented.height * model.cropCanvas.height / model.screenshot.scale
            )
        } else {
            let content = contentNaturalSize(of: preview)
            let backdrop = model.state.backdrop
            natural = backdrop.enabled ? backdrop.canvasSize(forContent: content, pixelsPerPoint: 1) : content
        }
        let inset: CGFloat = 32
        let maxWidth = max(available.width - inset * 2, 50)
        let maxHeight = max(available.height - inset * 2, 50)
        let scale = min(1, maxWidth / natural.width, maxHeight / natural.height)
        return (CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded()), scale)
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
                compactCropBar
            } else {
                editBar(showSize: true)
                editBar(showSize: false)
                compactEditBar
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

            zoomControl

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

    /// The narrowest crop bar, for a small window with the sidebar(s) open.
    private var compactCropBar: some View {
        HStack(spacing: 8) {
            Picker("Aspect", selection: $model.cropAspect) {
                ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Aspect ratio")
            Spacer(minLength: 4)
            Button(action: model.resetPendingCrop) { Image(systemName: "arrow.counterclockwise") }
                .help("Reset crop")
            Button(action: model.cancelCrop) { Image(systemName: "xmark") }
                .keyboardShortcut(.cancelAction)
                .help("Cancel (Esc)")
            Button("Done", action: model.commitCrop)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// The narrowest edit bar: icons instead of labels.
    private var compactEditBar: some View {
        HStack(spacing: 8) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Undo (⌘Z)")
            zoomControl
            Spacer(minLength: 4)
            Button { model.pin() } label: { Image(systemName: "pin") }
                .help("Pin to screen")
            Button { model.copyToPasteboard() } label: { Image(systemName: "doc.on.doc") }
                .help("Copy to clipboard (⌘C)")
            Button { model.saveAs() } label: { Image(systemName: "square.and.arrow.down.on.square") }
                .help("Save to a new location (⇧⌘S)")
            Button("Save") { model.save() }
                .buttonStyle(.borderedProminent)
                .help("Save (⌘S)")
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
                Text(abs(model.zoom - 1) > 0.001 ? "\(model.zoomPercent)%" : "Fit")
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
                backgroundButton

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

                Button("Revert to Original", role: .destructive, action: model.resetAll)
                    .disabled(model.state.isIdentity)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Adding a background is a headline action: a prominent button that turns it
    /// on and opens its options in the left panel.
    @ViewBuilder
    private var backgroundButton: some View {
        if model.state.backdrop.enabled {
            Button {
                if model.isCropping {
                    model.commitCrop() // finish the crop, then show the background options
                    model.showsBackgroundPanel = true
                } else {
                    model.showsBackgroundPanel.toggle()
                }
            } label: {
                Label(model.showsBackgroundPanel && !model.isCropping ? "Hide Background Options" : "Edit Background", systemImage: "photo.artframe")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        } else {
            Button(action: model.addBackground) {
                Label("Add Background", systemImage: "photo.artframe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Put the screenshot on a gradient, color or image, with padding, rounded corners and a shadow")
        }
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

/// The left-hand panel shown while adding or editing a background.
private struct BackgroundPanel: View {
    @ObservedObject var model: EditorModel

    private var backdrop: Backdrop { model.state.backdrop }
    private let swatchColumns = Array(repeating: GridItem(.fixed(30), spacing: 8), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Background", systemImage: "photo.artframe")
                    .font(.headline)
                Spacer()
                Button {
                    model.showsBackgroundPanel = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                options
                    .padding(16)
            }
            Divider()
            Button(role: .destructive, action: model.removeBackground) {
                Label("Remove Background", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(12)
            .disabled(!backdrop.enabled)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            if backdrop.enabled {
                ForEach(GradientPreset.Category.allCases) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.rawValue)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 8) {
                            ForEach(GradientPreset.all.filter { $0.category == category }) { preset in
                                Swatch(isSelected: backdrop.fill == .gradient(id: preset.id), help: preset.name) {
                                    model.updateBackdrop { $0.fill = .gradient(id: preset.id) }
                                } content: {
                                    PresetSwatch(preset: preset).equatable()
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Other")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Swatch(isSelected: backdrop.fill == .transparent, help: "Transparent") {
                            model.updateBackdrop { $0.fill = .transparent }
                        } content: {
                            TransparencyPattern()
                        }
                        Swatch(isSelected: isImageFill, help: "Choose Image…", action: model.chooseBackgroundImage) {
                            ZStack {
                                Color(nsColor: .controlBackgroundColor)
                                Image(systemName: "photo")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ColorPicker("Solid color", selection: solidColor, supportsOpacity: true)
                            .font(.callout)
                            .padding(.leading, 4)
                    }
                }

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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicking the empty canvas around the image deselects the selected layer.
    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            window?.makeFirstResponder(nil)
            model.selectedAnnotationID = nil
        }
    }

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
        guard event.window === window else { return event }
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

/// Draws a background fill with the same Core Graphics code export uses, so
/// gradients and textures look identical live and in the saved image.
/// Equatable so the (possibly heavy) texture is only redrawn when the background
/// itself changes, not on every zoom, pan, toast or drawing change.
private struct BackdropFillView: View, Equatable {
    let backdrop: Backdrop
    let image: CGImage?
    /// View points per canvas point (texture scale).
    let pixelsPerPoint: CGFloat

    static func == (a: Self, b: Self) -> Bool {
        a.backdrop == b.backdrop && a.image === b.image && a.pixelsPerPoint == b.pixelsPerPoint
    }

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                // SwiftUI's context is y-down; the renderer works y-up like export.
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                backdrop.drawFill(in: cg, rect: CGRect(origin: .zero, size: size), backgroundImage: image, pixelsPerPoint: pixelsPerPoint)
            }
        }
    }
}

/// A preset preview for the swatch grid, drawn by the same renderer.
private struct PresetSwatch: View, Equatable {
    let preset: GradientPreset

    static func == (a: Self, b: Self) -> Bool { a.preset.id == b.preset.id }

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                preset.draw(in: cg, rect: CGRect(origin: .zero, size: size), pixelsPerPoint: 0.7)
            }
        }
    }
}
