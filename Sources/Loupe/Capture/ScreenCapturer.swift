import AppKit
import ScreenCaptureKit

/// A frozen image of one display, taken at native (backing) resolution.
struct DisplaySnapshot {
    let screen: NSScreen
    let image: CGImage

    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

/// An on-screen window that can be picked in the selection overlay.
struct WindowInfo {
    let id: CGWindowID
    /// In Cocoa global coordinates (bottom-left origin of the primary display).
    let frame: CGRect
    let ownerName: String
}

enum ScreenCapturer {
    /// Normal app windows, frontmost first (CGWindowList's order).
    @MainActor
    static func visibleWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        // CG window bounds are top-left based on the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 40, bounds.height >= 40,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { return nil }
            let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return WindowInfo(id: number, frame: frame, ownerName: info[kCGWindowOwnerName as String] as? String ?? "")
        }
    }

    /// Captures a single window on its own (even if partly covered), with
    /// transparent rounded corners and no shadow.
    @MainActor
    static func captureWindow(id: CGWindowID) async throws -> (image: CGImage, scale: CGFloat)? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Captures every connected display. Windows whose numbers are in
    /// `excludedWindowNumbers` (e.g. our quick access thumbnails) are hidden.
    @MainActor
    static func snapshotAllDisplays(excludingWindowNumbers excludedWindowNumbers: Set<Int> = []) async throws -> [DisplaySnapshot] {
        try await snapshot(screens: NSScreen.screens, excludingWindowNumbers: excludedWindowNumbers)
    }

    @MainActor
    static func snapshot(screens: [NSScreen], excludingWindowNumbers excludedWindowNumbers: Set<Int> = []) async throws -> [DisplaySnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excludedWindows = content.windows.filter { excludedWindowNumbers.contains(Int($0.windowID)) }

        var snapshots: [DisplaySnapshot] = []
        for screen in screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            if let colorSpace = screen.colorSpace?.cgColorSpace?.name {
                config.colorSpaceName = colorSpace
            }

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            snapshots.append(DisplaySnapshot(screen: screen, image: image))
        }
        return snapshots
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static var underMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main
    }
}
