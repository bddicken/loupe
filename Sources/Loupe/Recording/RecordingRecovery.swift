import AVFoundation
import AppKit

/// Saves recordings that a crash, force-quit or power loss interrupted. Movies are
/// written in fragments (see RecordingWriter), so what was recorded up to the last
/// fragment still plays.
@MainActor
enum RecordingRecovery {
    /// Run at launch, before anything records: converts each leftover movie to MP4 in
    /// the save folder, and says where they went.
    static func recoverUnfinished() {
        let directory = RecordingExport.unfinishedDirectory
        guard let movies = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ), !movies.isEmpty else { return }

        Task {
            var recovered: [URL] = []
            for movie in movies {
                guard await RecordingExport.playableDuration(of: movie) != nil else {
                    // Stopped before its first fragment: nothing to keep.
                    try? FileManager.default.removeItem(at: movie)
                    continue
                }
                let date = (try? movie.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                let destination = RecordingExport.newFileURL(for: date, format: .mp4)
                do {
                    try await RecordingExport.convertToMP4(movie, to: destination)
                    try? FileManager.default.removeItem(at: movie)
                    recovered.append(destination)
                } catch {
                    // Keep the movie as it is rather than lose it.
                    try? FileManager.default.removeItem(at: destination)
                    let fallback = destination.deletingPathExtension().appendingPathExtension("mov")
                    if (try? FileManager.default.moveItem(at: movie, to: fallback)) != nil {
                        recovered.append(fallback)
                    }
                }
            }
            guard !recovered.isEmpty else { return }
            NSLog("Loupe: recovered %d interrupted recording(s): %@", recovered.count, recovered.map(\.path).joined(separator: ", "))
            announce(recovered)
        }
    }

    private static func announce(_ files: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = files.count == 1
            ? "Loupe recovered a recording that was interrupted."
            : "Loupe recovered \(files.count) recordings that were interrupted."
        let folder = FileManager.default.displayName(atPath: files[0].deletingLastPathComponent().path)
        alert.informativeText = (files.count == 1 ? "It was" : "They were")
            + " saved to \(folder). The last couple of seconds before Loupe quit may be missing."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }
}
