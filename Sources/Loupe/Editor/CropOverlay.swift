import SwiftUI

/// Interactive crop rectangle drawn over the displayed image. `rect` is
/// normalized (0…1, top-left origin) so it is independent of display size.
struct CropOverlay: View {
    @Binding var rect: CGRect
    /// Width/height in normalized space, or nil for free-form.
    let aspect: CGFloat?
    let size: CGSize

    // `State` is used directly: the @State macro plugin ships only with Xcode.
    private let dragStartState = State<CGRect?>(initialValue: nil)
    private var dragStart: CGRect? {
        get { dragStartState.wrappedValue }
        nonmutating set { dragStartState.wrappedValue = newValue }
    }

    private let minimumSize: CGFloat = 0.02

    enum Handle: CaseIterable, Hashable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
    }

    var body: some View {
        let frame = CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )

        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(frame)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
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

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                var moved = start
                moved.origin.x = min(max(start.minX + value.translation.width / size.width, 0), 1 - start.width)
                moved.origin.y = min(max(start.minY + value.translation.height / size.height, 0), 1 - start.height)
                rect = moved
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                rect = resized(
                    start,
                    handle: handle,
                    dx: value.translation.width / size.width,
                    dy: value.translation.height / size.height
                )
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resized(_ start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.movesLeft { minX = min(max(minX + dx, 0), maxX - minimumSize) }
        if handle.movesRight { maxX = max(min(maxX + dx, 1), minX + minimumSize) }
        if handle.movesTop { minY = min(max(minY + dy, 0), maxY - minimumSize) }
        if handle.movesBottom { maxY = max(min(maxY + dy, 1), minY + minimumSize) }

        guard let aspect else {
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        var width = maxX - minX
        var height = maxY - minY

        if handle.isCorner {
            // Width drives height; shrink if the anchored corner runs out of room.
            height = width / aspect
            let available = handle.movesTop ? start.maxY : 1 - start.minY
            if height > available {
                height = available
                width = height * aspect
            }
            let x = handle.movesLeft ? start.maxX - width : start.minX
            let y = handle.movesTop ? start.maxY - height : start.minY
            return CGRect(x: x, y: y, width: width, height: height)
        }

        if handle.movesLeft || handle.movesRight {
            height = min(width / aspect, 1)
            width = height * aspect
            let x = handle.movesLeft ? start.maxX - width : start.minX
            let y = min(max(start.midY - height / 2, 0), 1 - height)
            return CGRect(x: x, y: y, width: width, height: height)
        }

        width = min(height * aspect, 1)
        height = width / aspect
        let x = min(max(start.midX - width / 2, 0), 1 - width)
        let y = handle.movesTop ? start.maxY - height : start.minY
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
