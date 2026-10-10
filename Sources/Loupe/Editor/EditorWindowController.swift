import AppKit
import Combine
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [EditorWindowController] = []

    private let model: EditorModel
    private var cancellables: Set<AnyCancellable> = []

    static func open(_ screenshot: Screenshot) {
        let controller = EditorWindowController(screenshot: screenshot)
        open.append(controller)
        // Show in the Dock and ⌘-Tab while an editor is open.
        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(screenshot: Screenshot) {
        model = EditorModel(screenshot: screenshot)
        let window = EditorWindow(model: model)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.setContentSize(Self.initialContentSize(for: screenshot))
        window.center()
        window.setFrameAutosaveName("") // Each editor opens centered.

        // Title + "edited" dot follow the model.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        guard let window else { return }
        window.title = model.screenshot.fileURL?.lastPathComponent ?? "Screenshot"
        window.representedURL = model.screenshot.fileURL
        window.isDocumentEdited = model.isDirty
    }

    private static func initialContentSize(for screenshot: Screenshot) -> NSSize {
        let sidebar: CGFloat = 260
        let chrome = NSSize(width: sidebar + 64, height: 64 + 56 + 40)
        let natural = screenshot.pointSize
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame.size
        let width = min(max(natural.width + chrome.width, 900), visible.width * 0.85)
        let height = min(max(natural.height + chrome.height, 560), visible.height * 0.85)
        return NSSize(width: width, height: height)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
        if Self.open.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Handles the menu/key-equivalent actions (⌘C, ⌘S, ⇧⌘S, ⌘Z, ⇧⌘Z).
final class EditorWindow: NSWindow {
    private let model: EditorModel

    @MainActor
    init(model: EditorModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
    }

    @objc func copy(_ sender: Any?) {
        MainActor.assumeIsolated { model.copyToPasteboard() }
    }

    @objc func saveDocument(_ sender: Any?) {
        MainActor.assumeIsolated { _ = model.save() }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        MainActor.assumeIsolated { _ = model.saveAs() }
    }

    @objc func undo(_ sender: Any?) {
        MainActor.assumeIsolated { model.undo() }
    }

    @objc func redo(_ sender: Any?) {
        MainActor.assumeIsolated { model.redo() }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            switch menuItem.action {
            case #selector(undo(_:)): model.canUndo && !model.isCropping
            case #selector(redo(_:)): model.canRedo && !model.isCropping
            default: super.validateMenuItem(menuItem)
            }
        }
    }
}
