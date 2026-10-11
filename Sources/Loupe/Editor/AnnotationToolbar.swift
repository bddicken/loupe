import SwiftUI

struct AnnotationToolbar: View {
    @ObservedObject var model: EditorModel

    private static let palette: [RGBAColor] = [
        RGBAColor(hex: 0xFF3B30), // red
        RGBAColor(hex: 0xFF9500), // orange
        RGBAColor(hex: 0xFFCC00), // yellow
        RGBAColor(hex: 0x34C759), // green
        RGBAColor(hex: 0x007AFF), // blue
        RGBAColor(hex: 0xAF52DE), // purple
        RGBAColor(hex: 0x000000),
        RGBAColor(hex: 0xFFFFFF),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            tools
        }
        .background(.bar)
        .disabled(model.isCropping)
    }

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    model.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 13))
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.tool == tool ? Color.accentColor.opacity(0.22) : .clear)
                        )
                        .foregroundStyle(model.tool == tool ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (\(String(tool.key).uppercased()))")
            }

            Divider().frame(height: 20).padding(.horizontal, 8)

            // Make clear what the color/size controls apply to.
            Text(model.selectedAnnotationID == nil ? "Next" : "Selected")
                .font(.caption.weight(.medium))
                .foregroundStyle(model.selectedAnnotationID == nil ? Color.secondary : Color.accentColor)
                .frame(width: 52, alignment: .trailing)
                .padding(.trailing, 4)
                .help(model.selectedAnnotationID == nil
                      ? "Color and size apply to the next shape you draw"
                      : "Color and size apply to the selected shape. Click empty space to deselect.")

            ForEach(Self.palette, id: \.self) { color in
                Button {
                    model.setAnnotationColor(color)
                } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                        .padding(3)
                        .overlay(
                            Circle().strokeBorder(model.toolbarColor == color ? Color.accentColor : .clear, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
            ColorPicker("Color", selection: customColor, supportsOpacity: true)
                .labelsHidden()
                .padding(.leading, 4)

            Divider().frame(height: 20).padding(.horizontal, 8)

            Image(systemName: "lineweight")
                .foregroundStyle(.secondary)
                .help("Size")
            Slider(value: size, in: 1...12) { editing in
                if editing, model.selectedAnnotationID != nil { model.checkpoint() }
            }
            .controlSize(.small)
            .frame(width: 90)

            if model.selectedAnnotationID != nil {
                Divider().frame(height: 20).padding(.horizontal, 8)
                Button {
                    model.deleteSelectedAnnotation()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete (⌫)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Picker changes after the first merge into one undo step.
    private var customColor: Binding<Color> {
        Binding(
            get: { model.toolbarColor.color },
            set: { model.setAnnotationColor(RGBAColor($0), checkpoint: false) }
        )
    }

    private var size: Binding<Double> {
        Binding(
            get: { model.toolbarSize },
            set: { model.setAnnotationSize($0, checkpoint: false) }
        )
    }
}
