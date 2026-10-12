import AppKit
import SwiftUI

/// Tools, colors and size. It takes plain values instead of observing the model, and
/// is Equatable, so edits that don't touch it (a dragged adjustment slider) skip it.
struct AnnotationToolbar: View, Equatable {
    /// For actions only: what's shown comes from `values`.
    let model: EditorModel
    let values: Values

    struct Values: Equatable {
        var tool: AnnotationTool
        var hasSelection: Bool
        var color: RGBAColor
        var size: Double
        var sizeLabel: String
        var styleApplies: Bool
        var isCropping: Bool
    }

    init(model: EditorModel) {
        self.model = model
        values = Values(
            tool: model.tool,
            hasSelection: model.selectedAnnotationID != nil,
            color: model.toolbarColor,
            size: model.toolbarSize,
            sizeLabel: model.toolbarSizeLabel,
            styleApplies: model.toolbarStyleApplies,
            isCropping: model.isCropping
        )
    }

    static func == (a: Self, b: Self) -> Bool { a.model === b.model && a.values == b.values }

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
        // Every button is its own item, so a narrow window wraps the toolbar onto more
        // rows (whole groups when they fit, single buttons when not) instead of cutting it off.
        ToolbarFlowLayout {
            ForEach(AnnotationTool.allCases) { tool in
                toolButton(tool)
            }
            ToolbarSeparator()
            styleLabel
                .modifier(StyleAvailability(applies: values.styleApplies))
            ForEach(Self.palette, id: \.self) { color in
                swatch(color)
                    .modifier(StyleAvailability(applies: values.styleApplies))
            }
            CustomColorButton(
                color: values.color,
                isCustom: !Self.palette.contains(values.color),
                open: openColorPanel
            )
            .padding(.leading, 2)
            .modifier(StyleAvailability(applies: values.styleApplies))
            ToolbarSeparator()
            sizeControl
            ToolbarSeparator()
            // Always there (dimmed with nothing selected), so selecting a shape never
            // changes the toolbar's size and moves the image.
            Button {
                model.deleteSelectedAnnotation()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!values.hasSelection)
            .opacity(values.hasSelection ? 1 : 0.35)
            .help("Delete Selected Shape (⌫)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .disabled(values.isCropping)
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button {
            model.tool = tool
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(values.tool == tool ? Color.accentColor.opacity(0.22) : .clear)
                )
                .foregroundStyle(values.tool == tool ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help("\(tool.title) (\(String(tool.key).uppercased()))")
    }

    /// Blur and pixelate have no color or size, so those controls dim for them.
    private var styleHelp: String {
        if !values.styleApplies { return "Blur and pixelate have no color or size" }
        return !values.hasSelection
            ? "Color and size apply to the next shape you draw"
            : "Color and size apply to the selected shape and the next ones you draw"
    }

    /// Makes clear what the color/size controls apply to. As wide as the longer word
    /// so the swatches don't shift, and leading so a wrapped row lines up.
    private var styleLabel: some View {
        ZStack(alignment: .leading) {
            Text("Selected").hidden()
            Text(values.hasSelection ? "Selected" : "Next")
                .foregroundStyle(!values.hasSelection ? Color.secondary : Color.accentColor)
        }
        .font(.caption.weight(.medium))
        .padding(.trailing, 4)
        .help(styleHelp)
    }

    private func swatch(_ color: RGBAColor) -> some View {
        Button {
            model.setAnnotationColor(color)
        } label: {
            Circle()
                .fill(color.color)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                .padding(3)
                .overlay(
                    Circle().strokeBorder(values.color == color ? Color.accentColor : .clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }

    private var sizeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "lineweight")
                .foregroundStyle(.secondary)
            Slider(value: size, in: EditorModel.annotationSizeRange) { editing in
                if editing, model.selectedAnnotationID != nil { model.checkpoint() }
            }
            .controlSize(.small)
            .frame(width: 90)
            Text(values.sizeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
        }
        .help(values.styleApplies ? "Size" : styleHelp)
        .modifier(StyleAvailability(applies: values.styleApplies))
    }

    /// Opens the system color panel. Its continuous changes to one layer (or to the
    /// next shape's color) merge into one undo step.
    private func openColorPanel() {
        var undoTarget: UUID?? = nil // The layer the current undo step covers.
        CustomColorPanel.shared.open(color: model.toolbarColor) { [weak model] color in
            guard let model, model.toolbarStyleApplies else { return }
            let target = model.selectedAnnotationID
            let isNewStep = undoTarget != .some(target)
            undoTarget = .some(target)
            model.setAnnotationColor(color, checkpoint: isNewStep)
        }
    }

    /// Whole steps, so the readout matches what's drawn.
    private var size: Binding<Double> {
        Binding(
            get: { values.size },
            set: { model.setAnnotationSize($0.rounded(), checkpoint: false) }
        )
    }
}

/// Dims and disables a color or size control while it doesn't apply (blur and pixelate).
private struct StyleAvailability: ViewModifier {
    let applies: Bool

    func body(content: Content) -> some View {
        content
            .disabled(!applies)
            .opacity(applies ? 1 : 0.35)
    }
}

/// A color-wheel ring that opens the color panel; it holds the color when it isn't
/// one of the palette's, so it never reads as another fixed swatch.
private struct CustomColorButton: View {
    let color: RGBAColor
    let isCustom: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            ZStack {
                Circle()
                    .strokeBorder(
                        AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center),
                        lineWidth: 3
                    )
                if isCustom {
                    Circle()
                        .fill(color.color)
                        .padding(4)
                }
            }
            .frame(width: 16, height: 16)
            .padding(3)
            .overlay(Circle().strokeBorder(isCustom ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Custom Color…")
    }
}

/// Routes the shared NSColorPanel's changes to whoever opened it last.
@MainActor
final class CustomColorPanel: NSObject {
    static let shared = CustomColorPanel()

    private var onChange: ((RGBAColor) -> Void)?

    func open(color: RGBAColor, onChange: @escaping (RGBAColor) -> Void) {
        let panel = NSColorPanel.shared
        // Detach first: setting the panel's color mustn't reach the previous editor.
        self.onChange = nil
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = color.nsColor
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        self.onChange = onChange
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(RGBAColor(Color(nsColor: sender.color)))
    }
}

/// A thin vertical rule between toolbar groups. ToolbarFlowLayout shows it only
/// between two groups on the same row (never at a row's start or end).
private struct ToolbarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            // Flexible, so the layout can hide it by proposing zero.
            .frame(maxWidth: ToolbarFlowLayout.separatorSize.width, maxHeight: ToolbarFlowLayout.separatorSize.height)
            .layoutValue(key: IsToolbarSeparator.self, value: true)
    }
}

private struct IsToolbarSeparator: LayoutValueKey {
    static let defaultValue = false
}

/// Lays items out left to right in groups (the runs between separators). A group that
/// doesn't fit on the current row starts a new one; a group wider than a whole row
/// breaks between its items. Nothing is ever clipped or scrolled.
private struct ToolbarFlowLayout: Layout {
    static let separatorSize = CGSize(width: 1, height: 20)
    /// Space on each side of a separator.
    var separatorGap: CGFloat = 8
    /// Space between items in a group.
    var itemSpacing: CGFloat = 2
    var rowSpacing: CGFloat = 6

    private struct Row {
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat?) -> [Row] {
        // Split into groups at the separators.
        var groups: [(separator: Int?, items: [(index: Int, size: CGSize)])] = []
        var separator: Int?
        var items: [(index: Int, size: CGSize)] = []
        for index in subviews.indices {
            if subviews[index][IsToolbarSeparator.self] {
                if !items.isEmpty { groups.append((separator, items)) }
                separator = index
                items = []
            } else {
                items.append((index, subviews[index].sizeThatFits(.unspecified)))
            }
        }
        if !items.isEmpty { groups.append((separator, items)) }

        let limit = maxWidth ?? .infinity
        let groupGap = separatorGap * 2 + Self.separatorSize.width
        var rows: [Row] = []
        var row = Row()
        func add(_ item: (index: Int, size: CGSize), at x: CGFloat) {
            row.items.append((item.index, x, item.size))
            row.width = x + item.size.width
            row.height = max(row.height, item.size.height)
        }
        for group in groups {
            let width = group.items.map(\.size.width).reduce(0, +) + itemSpacing * CGFloat(group.items.count - 1)
            var gap = itemSpacing
            if !row.items.isEmpty {
                let fitsWhole = row.width + groupGap + width <= limit
                // A group too wide for any row starts here and breaks between its items.
                let startsHere = width > limit && row.width + groupGap + group.items[0].size.width <= limit
                if fitsWhole || startsHere {
                    if let separator = group.separator {
                        row.items.append((separator, row.width + separatorGap, Self.separatorSize))
                    }
                    gap = groupGap
                } else {
                    rows.append(row)
                    row = Row()
                }
            }
            for item in group.items {
                let x = row.items.isEmpty ? 0 : row.width + gap
                if !row.items.isEmpty, x + item.size.width > limit {
                    rows.append(row)
                    row = Row()
                    add(item, at: 0)
                } else {
                    add(item, at: x)
                }
                gap = itemSpacing
            }
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, maxWidth: proposal.width)
        let height = rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var placed = Set<Int>()
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: y + row.height / 2),
                    anchor: .leading,
                    proposal: ProposedViewSize(item.size)
                )
                placed.insert(item.index)
            }
            y += row.height + rowSpacing
        }
        // Separators that fell at a row break.
        for index in subviews.indices where !placed.contains(index) {
            subviews[index].place(at: bounds.origin, proposal: .zero)
        }
    }
}
