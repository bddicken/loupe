import AppKit
import SwiftUI

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Loupe Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @AppStorage(Preferences.Key.autoSave) private var autoSave = true
    @AppStorage(Preferences.Key.copyToClipboard) private var copyToClipboard = false
    @AppStorage(Preferences.Key.showQuickAccess) private var showQuickAccess = true
    @AppStorage(Preferences.Key.playSound) private var playSound = true
    @AppStorage(Preferences.Key.imageFormat) private var imageFormat = ImageFormat.png.rawValue
    // `State` is used directly: the @State macro plugin ships only with Xcode.
    private let saveDirectoryState = State(initialValue: Preferences.saveDirectory)
    private var saveDirectory: URL { saveDirectoryState.wrappedValue }

    var body: some View {
        Form {
            Section("After capture") {
                Toggle("Save to folder automatically", isOn: $autoSave)
                Toggle("Copy to clipboard", isOn: $copyToClipboard)
                Toggle("Show quick access thumbnail", isOn: $showQuickAccess)
                Toggle("Play sound", isOn: $playSound)
            }

            Section("Saving") {
                LabeledContent("Folder") {
                    HStack {
                        Text(saveDirectory.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Format", selection: $imageFormat) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
            }

            Section("Shortcuts") {
                ForEach(Shortcut.allCases, id: \.self) { shortcut in
                    LabeledContent(shortcut.title, value: shortcut.displayString)
                }
                Text("In the capture overlay: drag to select, hold ⇧ for a square, Esc or right-click to cancel. In adjust mode, move/resize the selection, use arrow keys to nudge, then press Return or double-click to capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectory
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Preferences.saveDirectory = url
        saveDirectoryState.wrappedValue = url
    }
}
