import AppKit
import ServiceManagement
import SwiftUI

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?
    private static var tabs: SettingsTabViewController?
    private static let model = SettingsModel()

    static func show() {
        model.refresh()
        if window == nil {
            let tabs = SettingsTabViewController(model: model)
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .resizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: SettingsTabViewController.width, height: SettingsTabViewController.minHeight)
            window.contentMaxSize = NSSize(width: SettingsTabViewController.width, height: .greatestFiniteMagnitude)
            tabs.fitWindow(animated: false)
            window.center()
            self.window = window
            self.tabs = tabs
        } else {
            // Content may have changed (e.g. a login item message); refit unless the user is mid-resize.
            tabs?.fitWindow(animated: false)
        }
        DockPresence.show()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The settings panes, shown as toolbar tabs like macOS's own settings windows.
enum SettingsPane: Int, CaseIterable {
    case general, capture, recording, shortcuts

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .recording: "Recording"
        case .shortcuts: "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera.viewfinder"
        case .recording: "record.circle"
        case .shortcuts: "keyboard"
        }
    }
}

/// Toolbar-tabbed settings. Each pane sizes the window to its content, but never
/// taller than the screen: anything that doesn't fit scrolls, and the window can be
/// resized vertically.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    static let width: CGFloat = 520
    static let minHeight: CGFloat = 220
    private static let selectedPaneKey = "settingsSelectedPane"

    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        for pane in SettingsPane.allCases {
            let controller = NSHostingController(rootView: SettingsPaneView(pane: pane, model: model))
            // The window size is managed here; don't let the form's ideal size pin it.
            controller.sizingOptions = []
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            addTabViewItem(item)
        }
        let saved = UserDefaults.standard.integer(forKey: Self.selectedPaneKey)
        selectedTabViewItemIndex = SettingsPane(rawValue: saved) == nil ? 0 : saved
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var selectedPane: SettingsPane {
        SettingsPane(rawValue: selectedTabViewItemIndex) ?? .general
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The toolbar exists now, so the chrome height is final.
        fitWindow(animated: false)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.selectedPaneKey)
        fitWindow(animated: view.window?.isVisible == true)
    }

    /// The pane's natural height at the settings width.
    static func idealHeight(of pane: SettingsPane, model: SettingsModel) -> CGFloat {
        let measuring = NSHostingView(rootView: SettingsPaneView(pane: pane, model: model)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        return ceil(measuring.fittingSize.height)
    }

    /// Resizes the window to fit the selected pane, keeping its top edge in place and
    /// the whole window within the screen's visible area.
    /// `visibleFrame` overrides the screen's usable area (for testing small displays).
    func fitWindow(animated: Bool, visibleFrame: NSRect? = nil) {
        guard let window = view.window else { return }
        let visible = visibleFrame ?? (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chrome = window.frame.height - window.contentLayoutRect.height
        let maxContent = max(Self.minHeight, visible.height - chrome - 40)
        let content = min(max(Self.idealHeight(of: selectedPane, model: model), Self.minHeight), maxContent)

        var frame = window.frame
        frame.size.height = content + chrome
        frame.size.width = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: content)).width
        frame.origin.y = window.frame.maxY - frame.height
        if window.isVisible {
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: animated)
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

private struct SettingsPaneView: View {
    let pane: SettingsPane
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
            switch pane {
            case .general: general
            case .capture: capture
            case .recording: recording
            case .shortcuts: shortcuts
            }
        }
        .formStyle(.grouped)
        .onDisappear { model.stopRecording() }
    }

    // MARK: Panes

    @ViewBuilder private var general: some View {
        Section("Startup") {
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

    @ViewBuilder private var capture: some View {
        Section("After capture") {
            Toggle("Save to folder automatically", isOn: $autoSave)
            Toggle("Copy to clipboard", isOn: $copyToClipboard)
            Toggle("Show quick access thumbnail", isOn: $showQuickAccess)
            Toggle("Play sound", isOn: $playSound)
        }

        Section("Saving") {
            LabeledContent("Folder") {
                HStack {
                    Text(model.saveDirectory.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(model.saveDirectory.path(percentEncoded: false))
                    Button("Choose…", action: model.chooseFolder)
                }
            }
            Picker("Format", selection: $imageFormat) {
                ForEach(ImageFormat.allCases) { format in
                    Text(format.displayName).tag(format.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }

        Section("Self-timer") {
            Picker("Delay", selection: $timerSeconds) {
                ForEach([3, 5, 10], id: \.self) { Text("\($0) sec").tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    @ViewBuilder private var recording: some View {
        Section("Video") {
            Picker("Format", selection: $recordingFormat) {
                ForEach(RecordingFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Frame rate", selection: $recordingFrameRate) {
                ForEach([30, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }

        Section("While recording") {
            Toggle("Count down 3 seconds first", isOn: $recordingCountdown)
            Toggle("Show cursor", isOn: $recordCursor)
            Toggle("Highlight clicks", isOn: $highlightClicks)
        }

        Section {
            Toggle("Record microphone", isOn: $recordMicrophone)
            Toggle("Record computer audio", isOn: $recordSystemAudio)
        } header: {
            Text("Audio")
        } footer: {
            Text(recordingFormat == RecordingFormat.gif.rawValue
                ? "GIFs have no sound and are scaled to at most \(Int(GIFExporter.maxDimension)) px at \(GIFExporter.framesPerSecond) fps."
                : "Stop a recording with the Record Screen shortcut, the menu bar button, or the control bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(recordingFormat == RecordingFormat.gif.rawValue)
    }

    @ViewBuilder private var shortcuts: some View {
        Section {
            ForEach(Shortcut.allCases, id: \.self) { shortcut in
                shortcutRow(shortcut)
            }
        } footer: {
            Text("Click a shortcut and press a new key combination. Esc cancels, Delete removes it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            LabeledContent {
                Button("Open Keyboard Settings…", action: model.openKeyboardShortcutSettings)
            } label: {
                Text("macOS screenshot shortcuts")
                Text("⌘⇧3, ⌘⇧4 and ⌘⇧5 also open macOS's own tool. Turn those off if they win over Loupe.")
            }
        }

        Section("In the capture overlay") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drag to select, or click a window to capture just that window.")
                Text("Hold ⇧ for a square. Esc or right-click cancels.")
                Text("In adjust mode, move or resize the selection, nudge with the arrow keys, then press Return or double-click.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
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
