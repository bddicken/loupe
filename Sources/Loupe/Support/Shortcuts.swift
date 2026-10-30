import AppKit
import Carbon.HIToolbox

/// Global capture actions that can be bound to a hot key.
enum Shortcut: Int, CaseIterable {
    case area = 1
    case adjustableArea
    case fullscreen
    case previousArea
    case timedArea
    case timedFullscreen
    case recordScreen

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .adjustableArea: "Capture Area (Adjust, then Capture)"
        case .fullscreen: "Capture Fullscreen"
        case .previousArea: "Capture Previous Area"
        case .timedArea: "Capture Area with Timer"
        case .timedFullscreen: "Capture Fullscreen with Timer"
        case .recordScreen: "Record Screen"
        }
    }

    /// Defaults share the system's ⌘⇧ screenshot keys, so those need to be off in macOS.
    var defaultBinding: KeyBinding? {
        let modifiers = UInt32(cmdKey | shiftKey)
        switch self {
        case .area: return KeyBinding(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: modifiers, keyLabel: "4")
        case .adjustableArea: return KeyBinding(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: modifiers, keyLabel: "5")
        case .fullscreen: return KeyBinding(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: modifiers, keyLabel: "3")
        case .previousArea: return KeyBinding(keyCode: UInt32(kVK_ANSI_6), carbonModifiers: modifiers, keyLabel: "6")
        case .timedArea: return KeyBinding(keyCode: UInt32(kVK_ANSI_7), carbonModifiers: modifiers, keyLabel: "7")
        case .timedFullscreen: return nil
        case .recordScreen: return KeyBinding(keyCode: UInt32(kVK_ANSI_8), carbonModifiers: modifiers, keyLabel: "8")
        }
    }

    @MainActor
    func perform() {
        // An open dialog (a Save panel, an alert) would sit under the capture overlay and
        // block its clicks and keys, so don't start one. Stopping a recording is fine.
        if NSApp.modalWindow != nil, !(self == .recordScreen && ScreenRecordingController.shared.state == .recording) {
            NSSound.beep()
            return
        }
        switch self {
        case .area: CaptureController.shared.captureArea(mode: .quick)
        case .adjustableArea: CaptureController.shared.captureArea(mode: .adjustable)
        case .fullscreen: CaptureController.shared.captureFullscreen()
        case .previousArea: CaptureController.shared.capturePreviousArea()
        case .timedArea: CaptureController.shared.captureAreaWithTimer()
        case .timedFullscreen: CaptureController.shared.captureFullscreenWithTimer()
        case .recordScreen: ScreenRecordingController.shared.toggle()
        }
    }
}

struct KeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// Human-readable key, e.g. "4", "F5", "Space".
    var keyLabel: String

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags
        var modifiers: Int = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        carbonModifiers = UInt32(modifiers)
        keyLabel = Self.label(for: event)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    /// For NSMenuItem.keyEquivalent (display only in the status menu).
    var menuKeyEquivalent: String {
        if keyLabel.count == 1 { return keyLabel.lowercased() }
        if let index = Self.functionKeyCodes.firstIndex(of: Int(keyCode)) {
            return String(Character(UnicodeScalar(NSF1FunctionKey + index)!))
        }
        return ""
    }

    var isFunctionKey: Bool { Self.functionKeyCodes.contains(Int(keyCode)) }

    private static let functionKeyCodes = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static func label(for event: NSEvent) -> String {
        let code = Int(event.keyCode)
        if let index = functionKeyCodes.firstIndex(of: code) { return "F\(index + 1)" }
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            // The unmodified character, so ⇧4 shows "4" rather than "$".
            let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
            return characters.uppercased()
        }
    }
}

/// Stores bindings in UserDefaults and keeps the Carbon hot keys in sync.
@MainActor
final class ShortcutCenter {
    static let shared = ShortcutCenter()
    static let didChange = Notification.Name("LoupeShortcutsDidChange")

    /// Shortcuts that couldn't be registered (usually taken by another app).
    private(set) var unavailable: Set<Shortcut> = []

    private init() {}

    private func defaultsKey(_ shortcut: Shortcut) -> String { "shortcut.\(shortcut.rawValue)" }

    /// nil means the user removed the shortcut.
    func binding(for shortcut: Shortcut) -> KeyBinding? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(shortcut)) else {
            return shortcut.defaultBinding
        }
        return try? JSONDecoder().decode(KeyBinding.self, from: data)
    }

    func setBinding(_ binding: KeyBinding?, for shortcut: Shortcut) {
        // Taking a combination away from another action clears it there.
        if let binding {
            for other in Shortcut.allCases where other != shortcut && self.binding(for: other) == binding {
                store(nil, for: other)
            }
        }
        store(binding, for: shortcut)
        apply()
    }

    func resetToDefault(_ shortcut: Shortcut) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(shortcut))
        if let binding = shortcut.defaultBinding {
            setBinding(binding, for: shortcut)
        } else {
            apply()
        }
    }

    private func store(_ binding: KeyBinding?, for shortcut: Shortcut) {
        // An encoded `nil` ("null") records an explicit "no shortcut".
        let data = (try? JSONEncoder().encode(binding)) ?? Data()
        UserDefaults.standard.set(data, forKey: defaultsKey(shortcut))
    }

    /// (Re)registers every hot key.
    func apply() {
        HotKeyManager.shared.unregisterAll()
        unavailable = []
        for shortcut in Shortcut.allCases {
            guard let binding = binding(for: shortcut) else { continue }
            let ok = HotKeyManager.shared.register(keyCode: binding.keyCode, modifiers: binding.carbonModifiers) {
                shortcut.perform()
            }
            if !ok { unavailable.insert(shortcut) }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Hot keys swallow their key combos, so pause them while recording a new one.
    func suspend() {
        HotKeyManager.shared.unregisterAll()
    }
}
