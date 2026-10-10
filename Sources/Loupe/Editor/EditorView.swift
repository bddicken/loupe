import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                canvas
                Divider()
                bottomBar
            }
            Divider()
            EditorSidebar(model: model)
                .frame(width: 260)
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                CheckerboardBackground()

                if let preview = model.preview {
                    let size = displaySize(for: preview, in: geometry.size)
                    ZStack {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.width, height: size.height)

                        if model.isCropping {
                            CropOverlay(rect: $model.pendingCrop, aspect: model.normalizedAspect, size: size)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
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
            .animation(.easeOut(duration: 0.15), value: model.toast)
        }
    }

    /// Fit the image in the canvas, but never enlarge past its natural (point) size.
    private func displaySize(for preview: CGImage, in available: CGSize) -> CGSize {
        let pointsPerPreviewPixel = 1 / (model.previewScale * model.screenshot.scale)
        let natural = CGSize(
            width: CGFloat(preview.width) * pointsPerPreviewPixel,
            height: CGFloat(preview.height) * pointsPerPreviewPixel
        )
        let inset: CGFloat = 32
        let maxWidth = max(available.width - inset * 2, 50)
        let maxHeight = max(available.height - inset * 2, 50)
        let scale = min(1, maxWidth / natural.width, maxHeight / natural.height)
        return CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 10) {
            if model.isCropping {
                Picker("Aspect", selection: $model.cropAspect) {
                    ForEach(CropAspect.allCases) { aspect in
                        Text(aspect.rawValue).tag(aspect)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)

                Spacer()

                Text(sizeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Reset", action: model.resetPendingCrop)
                Button("Cancel", action: model.cancelCrop)
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: model.commitCrop)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .help("Undo (⌘Z)")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .help("Redo (⇧⌘Z)")

                Text(sizeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)

                Spacer()

                Button("Copy") { model.copyToPasteboard() }
                    .help("Copy to clipboard (⌘C)")
                Button("Save As…") { model.saveAs() }
                    .help("Save to a new location (⇧⌘S)")
                Button("Save") { model.save() }
                    .help(model.screenshot.fileURL.map { "Save to \($0.lastPathComponent) (⌘S)" } ?? "Save (⌘S)")
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
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
                section("Crop & Rotate") {
                    Button {
                        model.isCropping ? model.commitCrop() : model.beginCrop()
                    } label: {
                        Label(model.isCropping ? "Finish Cropping" : "Crop", systemImage: "crop")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .keyboardShortcut("c", modifiers: [])

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
