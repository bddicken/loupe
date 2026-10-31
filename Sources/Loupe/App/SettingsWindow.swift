import AppKit
import ServiceManagement
import SwiftUI

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?
    private static let model = SettingsModel()

    static func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Loupe Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        model.refresh()
        DockPresence.show()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// State that SwiftUI's @State would normally hold (its macro plugin ships
/// only with Xcode), plus shortcut recording and the login item.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var saveDirectory = Preferences.saveDirectory
    @Published private(set) var recording: Shortcut?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemMessage: String?
    @Published private(set) var shortcutsVersion = 0
    @Published var automaticallyChecksForUpdates = UpdateController.shared.automaticallyChecksForUpdates {
        didSet { UpdateController.shared.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Loupe \(version) (\(build))"
    }

    private var monitor: Any?

    init() {
        NotificationCenter.default.addObserver(forName: ShortcutCenter.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shortcutsVersion += 1 }
        }
    }

    func refresh() {
        automaticallyChecksForUpdates = UpdateController.shared.automaticallyChecksForUpdates
        updateLoginItemStatus()
        shortcutsVersion += 1
    }

    // MARK: Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectory
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Preferences.saveDirectory = url
        saveDirectory = url
    }

    // MARK: Shortcuts

    func binding(for shortcut: Shortcut) -> KeyBinding? {
        ShortcutCenter.shared.binding(for: shortcut)
    }

    func isUnavailable(_ shortcut: Shortcut) -> Bool {
        ShortcutCenter.shared.unavailable.contains(shortcut)
    }

    func toggleRecording(_ shortcut: Shortcut) {
        if recording == shortcut {
            stopRecording()
        } else {
            startRecording(shortcut)
        }
    }

    private func startRecording(_ shortcut: Shortcut) {
        stopRecording()
        recording = shortcut
        ShortcutCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        ShortcutCenter.shared.apply()
    }

    private func record(_ event: NSEvent) {
        guard let shortcut = recording else { return }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 53 where modifiers.isEmpty: // Esc cancels
            stopRecording()
            return
        case 51 where modifiers.isEmpty, 117 where modifiers.isEmpty: // Delete clears
            ShortcutCenter.shared.setBinding(nil, for: shortcut)
            stopRecording()
            return
        default:
            break
        }
        let binding = KeyBinding(event: event)
        // Plain letters would fire while typing; require ⌘, ⌥ or ⌃ (F-keys are fine alone).
        guard !modifiers.intersection([.command, .option, .control]).isEmpty || binding.isFunctionKey else {
            NSSound.beep()
            return
        }
        ShortcutCenter.shared.setBinding(binding, for: shortcut)
        stopRecording()
    }

    func resetShortcut(_ shortcut: Shortcut) {
        stopRecording()
        ShortcutCenter.shared.resetToDefault(shortcut)
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemMessage = nil
        } catch {
            loginItemMessage = error.localizedDescription
        }
        updateLoginItemStatus()
    }

    private func updateLoginItemStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        if status == .requiresApproval {
            loginItemMessage = "Allow Loupe in System Settings → General → Login Items."
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func openKeyboardShortcutSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    @AppStorage(Preferences.Key.autoSave) private var autoSave = true
    @AppStorage(Preferences.Key.copyToClipboard) private var copyToClipboard = false
    @AppStorage(Preferences.Key.showQuickAccess) private var showQuickAccess = true
    @AppStorage(Preferences.Key.playSound) private var playSound = true
    @AppStorage(Preferences.Key.imageFormat) private var imageFormat = ImageFormat.png.rawValue
    @AppStorage(Preferences.Key.timerSeconds) private var timerSeconds = 5
    @AppStorage(Preferences.Key.recordingFormat) private var recordingFormat = RecordingFormat.mp4.rawValue
    @AppStorage(Preferences.Key.recordingFrameRate) private var recordingFrameRate = 60
    @AppStorage(Preferences.Key.recordingCountdown) private var recordingCountdown = true
    @AppStorage(Preferences.Key.recordCursor) private var recordCursor = true
    @AppStorage(Preferences.Key.highlightClicks) private var highlightClicks = false
    @AppStorage(Preferences.Key.recordMicrophone) private var recordMicrophone = false
    @AppStorage(Preferences.Key.recordSystemAudio) private var recordSystemAudio = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch Loupe at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let message = model.loginItemMessage {
                    HStack {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…", action: model.openLoginItemsSettings)
                            .controlSize(.small)
                    }
                }
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $model.automaticallyChecksForUpdates)
                LabeledContent(model.versionDescription) {
                    Button("Check Now") { UpdateController.shared.checkForUpdates(nil) }
                }
            }

            Section("After capture") {
                Toggle("Save to folder automatically", isOn: $autoSave)
                Toggle("Copy to clipboard", isOn: $copyToClipboard)
                Toggle("Show quick access thumbnail", isOn: $showQuickAccess)
                Toggle("Play sound", isOn: $playSound)
                Picker("Self-timer", selection: $timerSeconds) {
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }

            Section("Saving") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.saveDirectory.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: model.chooseFolder)
                    }
                }
                Picker("Format", selection: $imageFormat) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
            }

            Section {
                Picker("Format", selection: $recordingFormat) {
                    ForEach(RecordingFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker("Frame rate", selection: $recordingFrameRate) {
                    ForEach([30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Toggle("Count down 3 seconds before recording", isOn: $recordingCountdown)
                Toggle("Show cursor", isOn: $recordCursor)
                Toggle("Highlight clicks", isOn: $highlightClicks)
                Toggle("Record microphone", isOn: $recordMicrophone)
                    .disabled(recordingFormat == RecordingFormat.gif.rawValue)
                Toggle("Record computer audio", isOn: $recordSystemAudio)
                    .disabled(recordingFormat == RecordingFormat.gif.rawValue)
            } header: {
                Text("Screen recording")
            } footer: {
                Text("Stop a recording with the Record Screen shortcut, the menu bar button, or the control bar. GIFs have no sound and are scaled to at most \(Int(GIFExporter.maxDimension)) px at \(GIFExporter.framesPerSecond) fps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(Shortcut.allCases, id: \.self) { shortcut in
                    shortcutRow(shortcut)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Click a shortcut and press a new key combination. Esc cancels, Delete removes it. To use ⌘⇧3, ⌘⇧4 or ⌘⇧5, first turn off the macOS screenshot shortcuts.")
                    Button("Open Keyboard Shortcuts…", action: model.openKeyboardShortcutSettings)
                        .controlSize(.small)
                    Text("In the capture overlay: drag to select, or click a window to capture just that window. Hold ⇧ for a square, Esc or right-click to cancel. In adjust mode, move/resize the selection, nudge with arrow keys, then press Return or double-click.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { model.stopRecording() }
    }

    private func shortcutRow(_ shortcut: Shortcut) -> some View {
        // Reading the version re-renders rows when bindings change.
        let _ = model.shortcutsVersion
        let binding = model.binding(for: shortcut)
        let isRecording = model.recording == shortcut

        return LabeledContent {
            HStack(spacing: 6) {
                if model.isUnavailable(shortcut), !isRecording {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Another app is already using this shortcut")
                }
                Button {
                    model.toggleRecording(shortcut)
                } label: {
                    Text(isRecording ? "Type shortcut…" : (binding?.displayString ?? "None"))
                        .monospacedDigit()
                        .frame(minWidth: 110)
                }
                .tint(isRecording ? .accentColor : nil)
                .buttonStyle(.bordered)

                Button {
                    model.resetShortcut(shortcut)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset to \(shortcut.defaultBinding?.displayString ?? "None")")
                .disabled(binding == shortcut.defaultBinding)
            }
        } label: {
            Text(shortcut.title)
        }
    }
}
