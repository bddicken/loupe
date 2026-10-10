import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A captured (or opened) image plus where it lives on disk, if anywhere.
final class Screenshot {
    let image: CGImage
    /// Pixels per point of the display it came from (2 on Retina).
    let scale: CGFloat
    var fileURL: URL?
    let date: Date

    init(image: CGImage, scale: CGFloat, fileURL: URL? = nil, date: Date = Date()) {
        self.image = image
        self.scale = scale
        self.fileURL = fileURL
        self.date = date
    }

    /// Loads an image file, honoring Retina DPI metadata so it shows at its point size.
    static func load(from url: URL) -> Screenshot? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = properties?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        return Screenshot(image: image, scale: max(1, dpi / 72), fileURL: url)
    }

    var pointSize: NSSize {
        NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

enum ImageExport {
    static func defaultFileName(for date: Date, format: ImageFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Loupe \(formatter.string(from: date)).\(format.fileExtension)"
    }

    /// A non-colliding URL in the save directory.
    static func newFileURL(for date: Date, format: ImageFormat = Preferences.imageFormat) -> URL {
        let directory = Preferences.saveDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = defaultFileName(for: date, format: format)
        var url = directory.appendingPathComponent(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let stem = (base as NSString).deletingPathExtension
            url = directory.appendingPathComponent("\(stem) (\(counter)).\(format.fileExtension)")
            counter += 1
        }
        return url
    }

    static func data(for image: CGImage, format: ImageFormat, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            return nil
        }
        // DPI metadata lets Preview & co. show Retina captures at their point size.
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func write(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        let format = ImageFormat(url: url)
        guard let data = data(for: image, format: format, scale: scale) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    static func copyToPasteboard(_ image: CGImage, scale: CGFloat) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let nsImage = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        if let png = data(for: image, format: .png, scale: scale) {
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            pasteboard.setData(png, forType: .png)
            if let tiff = nsImage.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        } else {
            pasteboard.writeObjects([nsImage])
        }
    }

    @MainActor
    static func runSavePanel(for image: CGImage, scale: CGFloat, suggestedName: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = Preferences.saveDirectory
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try write(image, scale: scale, to: url)
            return url
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }
}

enum CaptureSound {
    private static let sound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
    }()

    @MainActor
    static func play() {
        guard Preferences.playSound else { return }
        sound?.stop()
        sound?.play()
    }
}
