import AppKit
import ServiceManagement
import SwiftUI

/// Width of the settings content. Kept stable so tab height doesn't change with wrapping.
private let settingsContentWidth: CGFloat = 520

/// Tall enough for every tab (the shortcuts list is the longest, about 460pt)
/// so switching tabs doesn't resize the window. Taller content still grows it,
/// up to the visible screen.
private let settingsPreferredContentHeight: CGFloat = 480

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?
    private static let model = SettingsModel()
    private static let toolbarDelegate = SettingsToolbarDelegate()

    static func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: settingsContentWidth, height: settingsPreferredContentHeight),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Loupe Settings"
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: SettingsView(model: model))
            // Don't let the form's ideal height resize the window. A single grouped
            // form of every setting is taller than many screens; each tab reports
            // its own height and `fit` clamps that to the visible frame.
            hosting.sizingOptions = []
            window.contentView = hosting
            window.contentMinSize = NSSize(width: settingsContentWidth, height: 240)
            window.contentMaxSize = NSSize(width: settingsContentWidth, height: 2000)

            let toolbar = NSToolbar(identifier: "LoupeSettings")
            toolbar.delegate = toolbarDelegate
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            toolbar.displayMode = .iconAndLabel
            toolbar.selectedItemIdentifier = model.page.itemIdentifier
            window.toolbar = toolbar
            window.toolbarStyle = .preference
            toolbarDelegate.onSelect = { page in
                model.page = page
            }

            window.center()
            self.window = window
        }
        model.refresh()
        clampToVisibleScreen()
        DockPresence.show()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Keeps the window tall enough for the tabs, but never taller than the visible screen.
    static func fit(contentHeight: CGFloat) {
        guard let window, contentHeight > 1 else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let margin: CGFloat = 16
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let maxContent = max(240, visible.height - chrome - margin)
        let width = min(settingsContentWidth, max(320, visible.width - margin))
        let height = min(max(ceil(contentHeight), min(settingsPreferredContentHeight, maxContent)), maxContent)
        let content = window.contentRect(forFrameRect: window.frame).size
        if abs(content.height - height) > 1 || abs(content.width - width) > 1 {
            window.setContentSize(NSSize(width: width, height: height))
        }
        var frame = window.frame
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
        window.contentMinSize = NSSize(width: width, height: 240)
        window.contentMaxSize = NSSize(width: width, height: maxContent)
    }

    private static func clampToVisibleScreen() {
        guard let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        guard visible.height > 1 else { return }
        var frame = window.frame
        if frame.height > visible.height - 16 { frame.size.height = visible.height - 16 }
        if frame.width > visible.width - 16 { frame.size.width = visible.width - 16 }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }
}

enum SettingsPage: String, CaseIterable {
    case general
    case capture
    case recording
    case shortcuts

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .recording: "Recording"
        case .shortcuts: "Shortcuts"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera.viewfinder"
        case .recording: "record.circle"
        case .shortcuts: "keyboard"
        }
    }

    var itemIdentifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }

    init?(itemIdentifier: NSToolbarItem.Identifier) {
        self.init(rawValue: itemIdentifier.rawValue)
    }
}

/// Preference-style toolbar tabs. Retained by `SettingsWindowController` because
/// `NSToolbar.delegate` is weak.
private final class SettingsToolbarDelegate: NSObject, NSToolbarDelegate {
    var onSelect: ((SettingsPage) -> Void)?

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPage.allCases.map(\.itemIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPage.allCases.map(\.itemIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPage.allCases.map(\.itemIdentifier)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let page = SettingsPage(itemIdentifier: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = page.title
        item.paletteLabel = page.title
        item.toolTip = page.title
        item.image = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: page.title)
        item.target = self
        item.action = #selector(select(_:))
        return item
    }

    @objc private func select(_ sender: NSToolbarItem) {
        guard let page = SettingsPage(itemIdentifier: sender.itemIdentifier) else { return }
        sender.toolbar?.selectedItemIdentifier = sender.itemIdentifier
        onSelect?(page)
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
    @Published var page: SettingsPage = .general
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
    @AppStorage(Preferences.Key.recordingFrameRate) private var recordingFrameRate = 30
    @AppStorage(Preferences.Key.recordingCountdown) private var recordingCountdown = true
    @AppStorage(Preferences.Key.recordCursor) private var recordCursor = true
    @AppStorage(Preferences.Key.highlightClicks) private var highlightClicks = false
    @AppStorage(Preferences.Key.recordMicrophone) private var recordMicrophone = false
    @AppStorage(Preferences.Key.recordSystemAudio) private var recordSystemAudio = false

    var body: some View {
        ScrollView {
            pageForm
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: SettingsContentHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(SettingsContentHeightKey.self) { height in
            SettingsWindowController.fit(contentHeight: height)
        }
        .onChange(of: model.page) { _, _ in
            model.stopRecording()
        }
        .onDisappear { model.stopRecording() }
    }

    @ViewBuilder
    private var pageForm: some View {
        switch model.page {
        case .general: generalForm
        case .capture: captureForm
        case .recording: recordingForm
        case .shortcuts: shortcutsForm
        }
    }

    private var generalForm: some View {
        Form {
            Section("Login") {
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
        }
    }

    private var captureForm: some View {
        Form {
            Section {
                Toggle("Save to folder automatically", isOn: $autoSave)
                Toggle("Copy to clipboard", isOn: $copyToClipboard)
                Toggle("Show quick access thumbnail", isOn: $showQuickAccess)
                Toggle("Play sound", isOn: $playSound)
                Picker("Self-timer", selection: $timerSeconds) {
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            } header: {
                Text("After capture")
            } footer: {
                Text("In the capture overlay: drag to select, or click a window to capture just that window. Hold ⇧ for a square, Esc or right-click to cancel. In adjust mode, move/resize the selection, nudge with arrow keys, then press Return or double-click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
    }

    private var recordingForm: some View {
        Form {
            Section {
                Picker("Format", selection: $recordingFormat) {
                    ForEach(RecordingFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker("Frame rate", selection: $recordingFrameRate) {
                    ForEach([30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
            } header: {
                Text("Format")
            } footer: {
                Text("GIFs have no sound and are scaled to at most \(Int(GIFExporter.maxDimension)) px at \(GIFExporter.framesPerSecond) fps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Count down 3 seconds before recording", isOn: $recordingCountdown)
                Toggle("Show cursor", isOn: $recordCursor)
                Toggle("Highlight clicks", isOn: $highlightClicks)
                Toggle("Record microphone", isOn: $recordMicrophone)
                    .disabled(recordingFormat == RecordingFormat.gif.rawValue)
                Toggle("Record computer audio", isOn: $recordSystemAudio)
                    .disabled(recordingFormat == RecordingFormat.gif.rawValue)
            } header: {
                Text("While recording")
            } footer: {
                Text("Stop a recording with the Record Screen shortcut, the menu bar button, or the control bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutsForm: some View {
        Form {
            Section("Capture") {
                ForEach(Shortcut.allCases.filter { $0 != .recordScreen }, id: \.self) { shortcut in
                    shortcutRow(shortcut)
                }
            }
            Section {
                shortcutRow(.recordScreen)
            } header: {
                Text("Recording")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Click a shortcut and press a new key combination. Esc cancels, Delete removes it. To use ⌘⇧3, ⌘⇧4 or ⌘⇧5, first turn off the macOS screenshot shortcuts.")
                    Button("Open Keyboard Shortcuts…", action: model.openKeyboardShortcutSettings)
                        .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
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

private struct SettingsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
