import AppKit

/// The main menu is only visible while an editor window is open (the app is
/// otherwise a menu bar accessory), but it also provides the key equivalents
/// (⌘C, ⌘S, ⌘Z, ⌘W …) that route through the responder chain to editor windows.
enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Loupe", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Loupe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Loupe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "Loupe")

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorWindow.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(EditorWindow.saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: fileMenu, title: "File")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: editMenu, title: "Edit")

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(EditorWindow.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(EditorWindow.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Zoom to Fit", action: #selector(EditorWindow.zoomToFit(_:)), keyEquivalent: "0")
        main.addItem(submenu: viewMenu, title: "View")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
