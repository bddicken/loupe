import AppKit
import ScreenCaptureKit

/// A frozen image of one display, taken at native (backing) resolution.
struct DisplaySnapshot {
    let screen: NSScreen
    let image: CGImage

    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

enum ScreenCapturer {
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
