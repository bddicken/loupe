import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        NSApp.mainMenu = MainMenu.build()
        setUpStatusItem()
        registerHotKeys()

        // `Loupe --edit <image>…` opens images straight in the editor (handy for development).
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--edit") {
            for path in arguments[(index + 1)...] {
                openInEditor(URL(fileURLWithPath: path))
            }
        }

        if !CGPreflightScreenCaptureAccess() {
            // Adds Loupe to System Settings > Privacy & Security > Screen Recording.
            CGRequestScreenCaptureAccess()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Loupe")
        }

        let menu = NSMenu()
        for shortcut in Shortcut.allCases {
            let item = NSMenuItem(title: shortcut.title, action: #selector(runShortcut(_:)), keyEquivalent: shortcut.keyEquivalent)
            item.keyEquivalentModifierMask = shortcut.modifierFlags
            item.tag = shortcut.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Image in Editor…", action: #selector(openImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Screenshots Folder", action: #selector(openScreenshotsFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Loupe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func runShortcut(_ sender: NSMenuItem) {
        guard let shortcut = Shortcut(rawValue: sender.tag) else { return }
        // Give the status menu time to fade out so it isn't captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            shortcut.perform()
        }
    }

    @objc private func openImage() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(openInEditor)
    }

    private func openInEditor(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        // Respect Retina DPI metadata so the editor shows the image at its point size.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = properties?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        let screenshot = Screenshot(image: image, scale: max(1, dpi / 72), fileURL: url)
        EditorWindowController.open(screenshot)
    }

    @objc private func openScreenshotsFolder() {
        let folder = Preferences.saveDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc func openSettings() {
        SettingsWindowController.show()
    }

    // MARK: - Hot keys

    private func registerHotKeys() {
        var failed: [String] = []
        for shortcut in Shortcut.allCases {
            let ok = HotKeyManager.shared.register(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers) {
                shortcut.perform()
            }
            if !ok { failed.append(shortcut.displayString) }
        }
        if !failed.isEmpty {
            NSLog("Loupe: could not register hot keys: \(failed.joined(separator: ", "))")
        }
    }
}

/// Global capture shortcuts. Defaults avoid the system's ⌘⇧3/4/5.
enum Shortcut: Int, CaseIterable {
    case area = 1
    case adjustableArea
    case fullscreen

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .adjustableArea: "Capture Area (Adjust, then Capture)"
        case .fullscreen: "Capture Fullscreen"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .area: UInt32(kVK_ANSI_4)
        case .adjustableArea: UInt32(kVK_ANSI_5)
        case .fullscreen: UInt32(kVK_ANSI_3)
        }
    }

    var keyEquivalent: String {
        switch self {
        case .area: "4"
        case .adjustableArea: "5"
        case .fullscreen: "3"
        }
    }

    var carbonModifiers: UInt32 { UInt32(optionKey | shiftKey) }
    var modifierFlags: NSEvent.ModifierFlags { [.option, .shift] }
    var displayString: String { "⌥⇧\(keyEquivalent)" }

    @MainActor
    func perform() {
        switch self {
        case .area: CaptureController.shared.captureArea(mode: .quick)
        case .adjustableArea: CaptureController.shared.captureArea(mode: .adjustable)
        case .fullscreen: CaptureController.shared.captureFullscreen()
        }
    }
}
