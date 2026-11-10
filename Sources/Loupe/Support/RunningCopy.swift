import Foundation

/// Notices when Loupe.app is replaced or deleted on disk while this copy keeps running,
/// e.g. a new version dragged over it from the DMG, or `scripts/build-app.sh` rebuilding
/// build/Loupe.app. The running process then has no executable on disk, so macOS can no
/// longer check its code signature, and authd refuses it. Sparkle needs authd to start
/// its installer, so updating fails with "An error occurred while launching the
/// installer". Only quitting and reopening Loupe fixes that.
enum RunningCopy {
    enum State: Equatable {
        /// The executable this process started from is still on disk.
        case intact
        /// Something else (usually another version) is now at the same path.
        case replaced
        /// Nothing is at the path any more: Loupe was moved or deleted.
        case removed
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static let executablePath = Bundle.main.executablePath

    /// Taken when `start()` runs, at launch, before anything could have replaced the app.
    private static let launchIdentity: FileIdentity? = executablePath.flatMap(identity(of:))

    /// Call once at launch to remember which file this process started from.
    static func start() {
        _ = launchIdentity
    }

    static var state: State {
        // Without a starting point there's nothing to compare; let updates go ahead as before.
        guard let launchIdentity, let executablePath else { return .intact }
        guard let current = identity(of: executablePath) else { return .removed }
        return current == launchIdentity ? .intact : .replaced
    }

    private static func identity(of path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }
}
