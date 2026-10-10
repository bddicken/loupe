import SwiftUI

/// Interactive crop rectangle drawn over the displayed image. `rect` is
/// normalized (image is 0…1, top-left origin) so it is independent of display
/// size, and may extend past the image without limit.
struct CropOverlay: View {
    @Binding var rect: CGRect
    /// Width/height in normalized space, or nil for free-form.
    let aspect: CGFloat?
    /// The normalized area shown in `size`: the image plus room around it.
    /// The crop can be dragged past it; `onDragEnded` lets the owner zoom out to fit.
    let bounds: CGRect
    let size: CGSize
    var onDragEnded: () -> Void = {}

    // `State` is used directly: the @State macro plugin ships only with Xcode.
    private let dragStartState = State<CGRect?>(initialValue: nil)
    private var dragStart: CGRect? {
        get { dragStartState.wrappedValue }
        nonmutating set { dragStartState.wrappedValue = newValue }
    }

    private let minimumSize: CGFloat = 0.02
    /// Edges dragged within this many points of the image's edges snap to them.
    private let snapDistance: CGFloat = 8

    enum Handle: CaseIterable, Hashable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
    }

    /// Maps a normalized rect into view points.
    static func viewRect(_ r: CGRect, bounds: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: (r.minX - bounds.minX) / bounds.width * size.width,
            y: (r.minY - bounds.minY) / bounds.height * size.height,
            width: r.width / bounds.width * size.width,
            height: r.height / bounds.height * size.height
        )
    }

    /// The image plus the crop, in view points: the only part of the canvas
    /// worth showing (elsewhere is just extended edge pixels).
    static func visibleArea(crop: CGRect, bounds: CGRect, size: CGSize) -> Path {
        Path(viewRect(EditorModel.fullRect, bounds: bounds, size: size))
            .union(Path(viewRect(crop, bounds: bounds, size: size)))
    }

    var body: some View {
        let frame = Self.viewRect(rect, bounds: bounds, size: size)

        ZStack(alignment: .topLeading) {
            Self.visibleArea(crop: rect, bounds: bounds, size: size)
                .subtracting(Path(frame))
                .fill(Color.black.opacity(0.55))
                .allowsHitTesting(false)

            // Rule-of-thirds guides.
            Path { path in
                for i in 1...2 {
                    let x = frame.minX + frame.width * CGFloat(i) / 3
                    let y = frame.minY + frame.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: frame.minY))
                    path.addLine(to: CGPoint(x: x, y: frame.maxY))
                    path.move(to: CGPoint(x: frame.minX, y: y))
                    path.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)

            Color.white.opacity(0.001)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .gesture(moveGesture)
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }

            ForEach(Handle.allCases, id: \.self) { handle in
                handleView(handle)
                    .position(position(of: handle, in: frame))
                    .gesture(resizeGesture(handle))
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "crop")
    }


    @ViewBuilder
    private func handleView(_ handle: Handle) -> some View {
        let hit = Color.white.opacity(0.001).frame(width: 24, height: 24)
        if handle.isCorner {
            hit.overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 2)
            )
        } else {
            let horizontal = handle == .top || handle == .bottom
            hit.overlay(
                Capsule()
                    .fill(Color.white)
                    .frame(width: horizontal ? 22 : 5, height: horizontal ? 5 : 22)
                    .shadow(color: .black.opacity(0.4), radius: 2)
            )
        }
    }

    private func position(of handle: Handle, in frame: CGRect) -> CGPoint {
        let x = handle.movesLeft ? frame.minX : handle.movesRight ? frame.maxX : frame.midX
        let y = handle.movesTop ? frame.minY : handle.movesBottom ? frame.maxY : frame.midY
        return CGPoint(x: x, y: y)
    }

    /// Normalized units per view point.
    private var unitsPerPoint: CGSize {
        CGSize(width: bounds.width / size.width, height: bounds.height / size.height)
    }

    /// Snaps `value` to the image's near or far edge (0 or 1) when within `threshold`.
    private func snapped(_ value: CGFloat, threshold: CGFloat) -> CGFloat {
        if abs(value) < threshold { return 0 }
        if abs(value - 1) < threshold { return 1 }
        return value
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                let units = unitsPerPoint
                let snapX = snapDistance * units.width, snapY = snapDistance * units.height
                var x = start.minX + value.translation.width * units.width
                var y = start.minY + value.translation.height * units.height
                // Snap whichever edge is near an image edge.
                x = snapped(x, threshold: snapX)
                x = snapped(x + start.width, threshold: snapX) - start.width
                y = snapped(y, threshold: snapY)
                y = snapped(y + start.height, threshold: snapY) - start.height
                rect.origin = CGPoint(x: x, y: y)
            }
            .onEnded { _ in
                dragStart = nil
                onDragEnded()
            }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                rect = resized(
                    start,
                    handle: handle,
                    dx: value.translation.width * unitsPerPoint.width,
                    dy: value.translation.height * unitsPerPoint.height
                )
            }
            .onEnded { _ in
                dragStart = nil
                onDragEnded()
            }
    }

    private func resized(_ start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let snapX = snapDistance * unitsPerPoint.width, snapY = snapDistance * unitsPerPoint.height
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.movesLeft { minX = min(snapped(minX + dx, threshold: snapX), maxX - minimumSize) }
        if handle.movesRight { maxX = max(snapped(maxX + dx, threshold: snapX), minX + minimumSize) }
        if handle.movesTop { minY = min(snapped(minY + dy, threshold: snapY), maxY - minimumSize) }
        if handle.movesBottom { maxY = max(snapped(maxY + dy, threshold: snapY), minY + minimumSize) }

        guard let aspect else {
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        var width = maxX - minX
        var height = maxY - minY

        if handle.isCorner {
            // Width drives height.
            height = width / aspect
            let x = handle.movesLeft ? start.maxX - width : start.minX
            let y = handle.movesTop ? start.maxY - height : start.minY
            return CGRect(x: x, y: y, width: width, height: height)
        }

        if handle.movesLeft || handle.movesRight {
            height = width / aspect
            let x = handle.movesLeft ? start.maxX - width : start.minX
            return CGRect(x: x, y: start.midY - height / 2, width: width, height: height)
        }

        width = height * aspect
        let y = handle.movesTop ? start.maxY - height : start.minY
        return CGRect(x: start.midX - width / 2, y: y, width: width, height: height)
    }
}
