import AppKit

/// On-screen chrome while recording: an outline around the recorded area, a
/// control bar, and (optionally) click ripples. The outline and control bar
/// are left out of the recording; the click ripples are recorded.
@MainActor
final class RecordingOverlay {
    struct Actions {
        let stop: () -> Void
        let restart: () -> Void
        let cancel: () -> Void
    }

    private let screen: NSScreen
    /// The recorded area in global (Cocoa) coordinates.
    private let area: CGRect
    private var outline: NSPanel?
    private var controls: NSPanel?
    private(set) var clickLayerWindow: NSPanel?
    private var clickMonitors: [Any] = []
    private var timeLabel: NSTextField?
    private let actions: Actions

    /// Windows to keep out of the recording.
    var excludedWindowNumbers: Set<Int> {
        Set([outline, controls].compactMap { $0?.windowNumber })
    }

    init(screen: NSScreen, localArea: CGRect, actions: Actions) {
        self.screen = screen
        area = localArea.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        self.actions = actions
    }

    func show(highlightClicks: Bool) {
        showOutline()
        showControls()
        if highlightClicks { showClickLayer() }
    }

    func close() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
        for panel in [outline, controls, clickLayerWindow] {
            panel?.orderOut(nil)
        }
        outline = nil
        controls = nil
        clickLayerWindow = nil
    }

    func update(elapsed: TimeInterval) {
        timeLabel?.stringValue = RecordingOverlay.format(elapsed)
    }

    static func format(_ elapsed: TimeInterval) -> String {
        let seconds = Int(elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Panels

    private func makePanel(frame: NSRect, level: NSWindow.Level = .screenSaver) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private var isFullscreen: Bool { area.insetBy(dx: 1, dy: 1).contains(screen.frame.insetBy(dx: 2, dy: 2)) }

    private func showOutline() {
        guard !isFullscreen else { return }
        let frame = area.insetBy(dx: -3, dy: -3)
        let panel = makePanel(frame: frame)
        panel.ignoresMouseEvents = true
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let border = CAShapeLayer()
        border.path = CGPath(rect: view.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        border.lineWidth = 2
        border.lineDashPattern = [6, 4]
        view.layer?.addSublayer(border)
        panel.contentView = view
        panel.orderFrontRegardless()
        outline = panel
    }

    private func showControls() {
        let bar = RecordingControlBar(actions: actions)
        let size = bar.fittingSize
        bar.frame = NSRect(origin: .zero, size: size)

        // Below the area if there's room, then above, otherwise inside along the bottom.
        let visible = screen.visibleFrame
        let gap: CGFloat = 14
        var origin = NSPoint(x: area.midX - size.width / 2, y: area.minY - size.height - gap)
        if origin.y < visible.minY + 8 {
            origin.y = area.maxY + gap
            if origin.y + size.height > visible.maxY - 8 {
                origin.y = max(area.minY, visible.minY) + 28
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)

        let panel = makePanel(frame: NSRect(origin: origin, size: size))
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.contentView = bar
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        controls = panel
        timeLabel = bar.timeLabel
    }

    // MARK: - Click ripples

    private func showClickLayer() {
        let panel = makePanel(frame: screen.frame, level: .screenSaver)
        panel.ignoresMouseEvents = true
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        panel.contentView = view
        panel.orderFrontRegardless()
        clickLayerWindow = panel

        let handler: (NSEvent) -> Void = { [weak self] event in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.ripple(at: location, secondary: event.type == .rightMouseDown) }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            clickMonitors.append(global)
        }
        // Clicks on Loupe's own windows (e.g. the control bar) aren't seen by the global monitor.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler(event)
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func ripple(at globalPoint: NSPoint, secondary: Bool) {
        guard let window = clickLayerWindow, let layer = window.contentView?.layer,
              screen.frame.contains(globalPoint) else { return }
        let point = NSPoint(x: globalPoint.x - screen.frame.minX, y: globalPoint.y - screen.frame.minY)
        let radius: CGFloat = 22
        let circle = CAShapeLayer()
        circle.frame = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        circle.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2), transform: nil)
        let color = secondary ? NSColor.systemBlue : NSColor.systemYellow
        circle.fillColor = color.withAlphaComponent(0.35).cgColor
        circle.strokeColor = color.withAlphaComponent(0.9).cgColor
        circle.lineWidth = 2
        circle.opacity = 0
        layer.addSublayer(circle)

        CATransaction.begin()
        CATransaction.setCompletionBlock { circle.removeFromSuperlayer() }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.2
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.5, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        circle.add(group, forKey: "ripple")
        CATransaction.commit()
    }
}

/// The floating recording controls: a dark capsule with a pulsing red dot,
/// the elapsed time, and Stop / Restart / Discard buttons.
private final class RecordingControlBar: NSView {
    let timeLabel = NSTextField(labelWithString: "0:00")
    private let actions: RecordingOverlay.Actions
    private let height: CGFloat = 40

    init(actions: RecordingOverlay.Actions) {
        self.actions = actions
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = height / 2
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        // The HUD material alone turns light grey over bright windows; tint it so the bar stays dark.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            tint.topAnchor.constraint(equalTo: background.topAnchor),
            tint.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(pulse, forKey: "pulse")

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.alignment = .left

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let stop = HUDButton(style: .stop, tip: "Stop and Save", action: actions.stop)
        let restart = HUDButton(style: .symbol("arrow.counterclockwise"), tip: "Restart", action: actions.restart)
        let discard = HUDButton(style: .symbol("trash"), tip: "Discard Recording", action: actions.cancel)

        let views: [NSView] = [dot, timeLabel, divider, stop, restart, discard]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: height),

            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),

            timeLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Room for "00:00" so the bar doesn't grow as time passes.
            timeLabel.widthAnchor.constraint(equalToConstant: 44),

            divider.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 4),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 20),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),

            stop.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 8),
            restart.leadingAnchor.constraint(equalTo: stop.trailingAnchor, constant: 2),
            discard.leadingAnchor.constraint(equalTo: restart.trailingAnchor, constant: 2),
            discard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        for button in [stop, restart, discard] {
            button.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A round, borderless button that highlights on hover and responds to the
/// first click (the control panel never activates Loupe).
private final class HUDButton: NSView {
    enum Style {
        case stop
        case symbol(String)
    }

    private let action: () -> Void
    private let size: CGFloat = 30
    private var isHovered = false { didSet { updateBackground() } }
    private var isPressed = false { didSet { updateBackground() } }

    init(style: Style, tip: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = size / 2
        toolTip = tip
        setAccessibilityRole(.button)
        setAccessibilityLabel(tip)

        switch style {
        case .stop:
            // A red disc with a white square, like a recorder's stop key.
            let disc = CALayer()
            disc.frame = CGRect(x: 4, y: 4, width: size - 8, height: size - 8)
            disc.cornerRadius = (size - 8) / 2
            disc.backgroundColor = NSColor.systemRed.cgColor
            let square = CALayer()
            square.frame = disc.bounds.insetBy(dx: 7.5, dy: 7.5)
            square.cornerRadius = 1.5
            square.backgroundColor = NSColor.white.cgColor
            disc.addSublayer(square)
            layer?.addSublayer(disc)
        case let .symbol(name):
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: tip)?.withSymbolConfiguration(configuration)
            let imageView = NSImageView(image: image ?? NSImage())
            imageView.contentTintColor = NSColor.white.withAlphaComponent(0.9)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { action() }
    }

    private func updateBackground() {
        let alpha: CGFloat = isPressed ? 0.24 : (isHovered ? 0.14 : 0)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }
}
