import AppKit
import Combine
import SwiftUI

/// Shows the editor's preview frames. Each frame is a GPU surface set straight on a
/// layer as it arrives: no SwiftUI update, no CPU copy or conversion, so the image
/// keeps up with a dragged slider.
struct PreviewSurface: NSViewRepresentable {
    let frames: CurrentValueSubject<PreviewFrame?, Never>
    /// Rounds the image's corners (view points).
    var cornerRadius: CGFloat = 0
    /// Shows only this area (view points, top-left origin), if given.
    var mask: CGPath?

    func makeNSView(context: Context) -> PreviewSurfaceView {
        PreviewSurfaceView(frames: frames)
    }

    func updateNSView(_ view: PreviewSurfaceView, context: Context) {
        view.cornerRadius = cornerRadius
        view.maskPath = mask
    }
}

final class PreviewSurfaceView: NSView {
    private var subscription: AnyCancellable?
    private var current: PreviewFrame?
    private let maskLayer = CAShapeLayer()

    var cornerRadius: CGFloat = 0 {
        didSet { if cornerRadius != oldValue { layer?.cornerRadius = cornerRadius } }
    }

    var maskPath: CGPath? {
        didSet {
            guard maskPath != oldValue else { return }
            withoutAnimation {
                maskLayer.path = maskPath
                layer?.mask = maskPath == nil ? nil : maskLayer
            }
        }
    }

    init(frames: CurrentValueSubject<PreviewFrame?, Never>) {
        super.init(frame: .zero)
        wantsLayer = true
        // The layer's contents are set directly; AppKit never redraws them.
        layerContentsRedrawPolicy = .never
        if let layer {
            layer.contentsGravity = .resize
            layer.masksToBounds = true
            layer.cornerCurve = .circular
        }
        subscription = frames.sink { [weak self] frame in
            MainActor.assumeIsolated { self?.show(frame) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func show(_ frame: PreviewFrame?) {
        current = frame
        withoutAnimation { layer?.contents = frame?.surface }
    }

    private func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        withoutAnimation { maskLayer.frame = bounds }
    }

    /// Only for snapshots (cacheDisplay draws views instead of compositing their
    /// layers); on screen the layer shows the surface.
    override func draw(_ dirtyRect: NSRect) {
        guard let image = current?.makeCGImage(), let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if let maskPath {
            context.addPath(maskPath)
        } else {
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        }
        context.clip()
        // The view is flipped; draw the image upright.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }
}
