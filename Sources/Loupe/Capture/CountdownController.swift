import AppKit

/// Self-timer HUD: a big countdown in the middle of the screen plus an
/// outline of the area about to be captured. Click the HUD to cancel.
@MainActor
final class CountdownController {
    private let screen: NSScreen
    private let highlight: CGRect?
    private var remaining: Int
    private var hud: NSPanel?
    private var outline: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?
    private var completion: ((Bool) -> Void)?

    init(screen: NSScreen, highlight: CGRect?, seconds: Int) {
        self.screen = screen
        self.highlight = highlight
        remaining = max(1, seconds)
    }

    /// Calls `completion(true)` when the countdown ends, `false` if cancelled.
    func start(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        showOutline()
        showHUD()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            finish(true)
        } else {
            label?.stringValue = "\(remaining)"
            NSSound(named: "Tink")?.play()
        }
    }

    @objc private func cancel() {
        finish(false)
    }

    private func finish(_ completed: Bool) {
        timer?.invalidate()
        timer = nil
        hud?.orderOut(nil)
        outline?.orderOut(nil)
        hud = nil
        outline = nil
        guard let completion else { return }
        self.completion = nil
        // Let the window server remove the HUD before the capture happens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            completion(completed)
        }
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    private func showHUD() {
        let size = NSSize(width: 160, height: 160)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let panel = makePanel(frame: frame)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 28

        let number = NSTextField(labelWithString: "\(remaining)")
        number.font = .monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        number.alignment = .center
        number.frame = NSRect(x: 0, y: 46, width: size.width, height: 90)
        background.addSubview(number)
        label = number

        let hint = NSButton(title: "Click to cancel", target: self, action: #selector(cancel))
        hint.isBordered = false
        hint.font = .systemFont(ofSize: 11)
        hint.contentTintColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 16, width: size.width, height: 20)
        background.addSubview(hint)

        // The whole HUD cancels on click.
        let cover = NSButton(title: "", target: self, action: #selector(cancel))
        cover.isTransparent = true
        cover.frame = background.bounds
        background.addSubview(cover)

        panel.contentView = background
        panel.orderFrontRegardless()
        hud = panel
    }

    private func showOutline() {
        guard let highlight else { return }
        let frame = highlight.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY).insetBy(dx: -3, dy: -3)
        let panel = makePanel(frame: frame)
        panel.ignoresMouseEvents = true
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let border = CAShapeLayer()
        border.path = CGPath(rect: view.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.controlAccentColor.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [6, 4]
        view.layer?.addSublayer(border)
        panel.contentView = view
        panel.orderFrontRegardless()
        outline = panel
    }
}
