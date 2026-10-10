import AppKit
import ImageIO

struct HistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let path: String
    let scale: Double
    /// True when the file lives in Loupe's history folder (and is deleted with the item).
    let ownsFile: Bool

    var url: URL { URL(fileURLWithPath: path) }
}

/// Recent captures. Screenshots saved to disk are referenced in place;
/// unsaved ones are kept as PNGs in Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var items: [HistoryItem] = []
    private var thumbnails: [UUID: NSImage] = [:]
    private let limit = 60

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Loupe/History", isDirectory: true)
    }()
    private var indexURL: URL { folder.appendingPathComponent("history.json") }

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let stored = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = stored
        }
        pruneMissing()
    }

    func add(_ screenshot: Screenshot) {
        let id = UUID()
        let item: HistoryItem
        if let url = screenshot.fileURL {
            item = HistoryItem(id: id, date: screenshot.date, path: url.path, scale: screenshot.scale, ownsFile: false)
        } else {
            let url = folder.appendingPathComponent("\(id.uuidString).png")
            guard (try? ImageExport.write(screenshot.image, scale: screenshot.scale, to: url)) != nil else { return }
            item = HistoryItem(id: id, date: screenshot.date, path: url.path, scale: screenshot.scale, ownsFile: true)
        }
        items.insert(item, at: 0)
        while items.count > limit {
            deleteFileIfOwned(items.removeLast())
        }
        save()
    }

    func remove(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        deleteFileIfOwned(item)
        save()
    }

    func clear() {
        items.forEach(deleteFileIfOwned)
        items.removeAll()
        thumbnails.removeAll()
        save()
    }

    func screenshot(for item: HistoryItem) -> Screenshot? {
        guard let screenshot = Screenshot.load(from: item.url) else { return nil }
        // History-owned copies aren't "saved" locations the editor should overwrite.
        if item.ownsFile { screenshot.fileURL = nil }
        return Screenshot(image: screenshot.image, scale: item.scale, fileURL: screenshot.fileURL, date: item.date)
    }

    func thumbnail(for item: HistoryItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnails[item.id] = image
        return image
    }

    /// Drops entries whose files were moved or deleted outside Loupe.
    func pruneMissing() {
        let existing = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.count != items.count {
            items = existing
            save()
        }
    }

    private func deleteFileIfOwned(_ item: HistoryItem) {
        if item.ownsFile { try? FileManager.default.removeItem(at: item.url) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
