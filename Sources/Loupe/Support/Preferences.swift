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
        static let timerSeconds = "timerSeconds"
        static let cropExtend = "cropExtend"
        static let recordingFormat = "recordingFormat"
        static let recordingFrameRate = "recordingFrameRate"
        static let recordingCountdown = "recordingCountdown"
        static let recordCursor = "recordCursor"
        static let highlightClicks = "highlightClicks"
        static let recordMicrophone = "recordMicrophone"
        static let recordSystemAudio = "recordSystemAudio"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.autoSave: true,
            Key.copyToClipboard: false,
            Key.showQuickAccess: true,
            Key.playSound: true,
            Key.imageFormat: ImageFormat.png.rawValue,
            Key.timerSeconds: 5,
            Key.recordingFormat: RecordingFormat.mp4.rawValue,
            Key.recordingFrameRate: 30,
            Key.recordingCountdown: true,
            Key.recordCursor: true,
            Key.highlightClicks: false,
            Key.recordMicrophone: false,
            Key.recordSystemAudio: false,
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
    static var timerSeconds: Int { registered { UserDefaults.standard.integer(forKey: Key.timerSeconds) } }
    static var recordingFrameRate: Int { registered { UserDefaults.standard.integer(forKey: Key.recordingFrameRate) } }
    static var recordingCountdown: Bool { registered { UserDefaults.standard.bool(forKey: Key.recordingCountdown) } }
    static var recordCursor: Bool { registered { UserDefaults.standard.bool(forKey: Key.recordCursor) } }
    static var highlightClicks: Bool { registered { UserDefaults.standard.bool(forKey: Key.highlightClicks) } }
    static var recordMicrophone: Bool { registered { UserDefaults.standard.bool(forKey: Key.recordMicrophone) } }
    static var recordSystemAudio: Bool { registered { UserDefaults.standard.bool(forKey: Key.recordSystemAudio) } }
    static var recordingFormat: RecordingFormat {
        registered { RecordingFormat(rawValue: UserDefaults.standard.string(forKey: Key.recordingFormat) ?? "") ?? .mp4 }
    }

    /// How the last crop past the image's edges was filled; new edits start from it.
    static var cropExtend: CropExtend {
        get { UserDefaults.standard.string(forKey: Key.cropExtend).flatMap(CropExtend.init) ?? .edgePixels }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.cropExtend) }
    }
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
