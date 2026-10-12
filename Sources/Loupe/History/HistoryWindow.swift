import AppKit
import SwiftUI

@MainActor
enum HistoryWindowController {
    private static var window: NSWindow?

    static func show() {
        HistoryStore.shared.pruneMissing()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Capture History"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HistoryView(store: .shared))
            window.contentMinSize = NSSize(width: 420, height: 300)
            window.center()
            self.window = window
        }
        DockPresence.show()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct HistoryView: View {
    @ObservedObject var store: HistoryStore

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No captures yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.items) { item in
                            HistoryCell(store: store, item: item)
                        }
                    }
                    .padding(16)
                }
            }

            Divider()
            HStack {
                Text("\(store.items.count) capture\(store.items.count == 1 ? "" : "s") · double-click to edit, right-click for more")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History", role: .destructive) {
                    store.clear()
                }
                .disabled(store.items.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 420, minHeight: 300)
    }
}

private struct HistoryCell: View {
    @ObservedObject var store: HistoryStore
    let item: HistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                CheckerPattern()
                if let thumbnail = store.thumbnail(for: item) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )

            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open in Editor", action: edit)
            Button("Copy", action: copy)
            Button("Pin to Screen", action: pin)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            Button("Remove from History") { store.remove(item) }
        }
    }

    private func edit() {
        if let screenshot = store.screenshot(for: item) {
            EditorWindowController.open(screenshot)
        }
    }

    private func copy() {
        if let screenshot = store.screenshot(for: item) {
            ImageExport.copyToPasteboard(screenshot.image, scale: screenshot.scale)
        }
    }

    private func pin() {
        if let screenshot = store.screenshot(for: item) {
            PinManager.shared.pin(screenshot)
        }
    }
}

private struct CheckerPattern: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.5, opacity: 0.08)))
            var path = Path()
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(Color(white: 0.5, opacity: 0.12)))
        }
    }
}
