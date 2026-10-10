import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        NSApp.mainMenu = MainMenu.build()
        setUpStatusItem()
        ShortcutCenter.shared.apply()
        NotificationCenter.default.addObserver(forName: ShortcutCenter.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildStatusMenu() }
        }

        // `Loupe --edit <image>…` opens images straight in the editor (handy for development).
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--edit") {
            for path in arguments[(index + 1)...] {
                openInEditor(URL(fileURLWithPath: path))
            }
        }

        // `Loupe --debug-status-item` logs where the menu bar icon ended up.
        if arguments.contains("--debug-status-item") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let button = self?.statusItem.button, let window = button.window else {
                    print("status item: no button window")
                    return
                }
                print("status item: frame \(window.frame), visible \(window.isVisible), " +
                      "occluded \(!window.occlusionState.contains(.visible)), itemVisible \(self?.statusItem.isVisible ?? false)")
                fflush(stdout)
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "LoupeStatusItem"
        statusItem.behavior = [] // Don't let ⌘-dragging remove it from the menu bar.
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = StatusBarIcon.make()
            button.toolTip = "Loupe"
        }
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        for shortcut in Shortcut.allCases {
            let binding = ShortcutCenter.shared.binding(for: shortcut)
            let item = NSMenuItem(title: shortcut.title, action: #selector(runShortcut(_:)), keyEquivalent: binding?.menuKeyEquivalent ?? "")
            item.keyEquivalentModifierMask = binding?.modifierFlags ?? []
            item.tag = shortcut.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Capture History…", action: #selector(openHistory), keyEquivalent: "").target = self
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

    @objc private func openHistory() {
        HistoryWindowController.show()
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
        guard let screenshot = Screenshot.load(from: url) else { return }
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
}
