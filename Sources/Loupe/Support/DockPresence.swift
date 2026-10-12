import AppKit

/// Loupe lives in the menu bar, but shows in the Dock and ⌘-Tab while one of its
/// ordinary windows (an editor, Settings, History, an update) is open, so it can
/// be switched back to.
@MainActor
enum DockPresence {
    /// Call when showing one of those windows.
    static func show() {
        NSApp.setActivationPolicy(.regular)
    }

    /// Whether one of those windows is open (thumbnails, pins and alerts don't count).
    static var hasWindows: Bool {
        NSApp.windows.contains { window in
            !(window is NSPanel) && window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
        }
    }

    /// Goes back to menu-bar-only once none of those windows are left.
    static func refresh() {
        NSApp.setActivationPolicy(hasWindows ? .regular : .accessory)
    }

    /// Refreshes after any window closes (including Sparkle's).
    static func startObserving() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // Once the closing window is actually gone.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { refresh() }
            }
        }
    }
}
