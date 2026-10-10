import Foundation
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg

    var id: String { rawValue }
    var displayName: String { self == .png ? "PNG" : "JPEG" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var utType: UTType { self == .png ? .png : .jpeg }

    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        self = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png
    }
}

/// UserDefaults-backed settings. Keys are shared with @AppStorage in SettingsView.
enum Preferences {
    enum Key {
        static let saveDirectory = "saveDirectory"
        static let autoSave = "autoSave"
        static let copyToClipboard = "copyToClipboard"
        static let showQuickAccess = "showQuickAccess"
        static let playSound = "playSound"
        static let imageFormat = "imageFormat"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.autoSave: true,
            Key.copyToClipboard: false,
            Key.showQuickAccess: true,
            Key.playSound: true,
            Key.imageFormat: ImageFormat.png.rawValue,
        ])
    }

    static var defaultSaveDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    static var saveDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: Key.saveDirectory), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return defaultSaveDirectory
        }
        set { UserDefaults.standard.set(newValue.path, forKey: Key.saveDirectory) }
    }

    static var autoSave: Bool { registered { UserDefaults.standard.bool(forKey: Key.autoSave) } }
    static var copyToClipboard: Bool { registered { UserDefaults.standard.bool(forKey: Key.copyToClipboard) } }
    static var showQuickAccess: Bool { registered { UserDefaults.standard.bool(forKey: Key.showQuickAccess) } }
    static var playSound: Bool { registered { UserDefaults.standard.bool(forKey: Key.playSound) } }
    static var imageFormat: ImageFormat {
        registered { ImageFormat(rawValue: UserDefaults.standard.string(forKey: Key.imageFormat) ?? "") ?? .png }
    }

    private static var didRegister = false
    private static func registered<T>(_ read: () -> T) -> T {
        if !didRegister {
            registerDefaults()
            didRegister = true
        }
        return read()
    }
}
