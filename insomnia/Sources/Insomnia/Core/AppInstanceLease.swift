import Darwin
import Foundation

/// The GUI owns this lease from before service construction until process exit.
/// A permanent inode makes independent launches agree on the same BSD flock.
@MainActor
final class AppInstanceLease {
    private static var processLease: AppInstanceLease?
    private let descriptor: Int32

    static func acquireForProcess(paths: Paths) throws {
        guard processLease == nil else { return }
        processLease = try AppInstanceLease(paths: paths)
    }

    init(paths: Paths, installerGuard: URL = Paths.installerGuard) throws {
        try Self.checkInstaller(installerGuard)
        try PrivateFiles.directory(paths.appSupport)
        let fd = open(paths.instanceLock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.system(errno) }
        do {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw Failure.alreadyRunning }
                throw Failure.system(errno)
            }
            // Cover an installer that acquired its guard during our lock open.
            // Later installer starts see this existing PID in their quit sweep.
            try Self.checkInstaller(installerGuard)
        } catch {
            _ = close(fd)
            throw error
        }
        descriptor = fd
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        // Never unlink instance.lock: another process may already have it open.
    }

    nonisolated static func isInstallationActive(at url: URL = Paths.installerGuard) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 || errno != ENOENT
    }

    private static func checkInstaller(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 { throw Failure.installing }
        guard errno == ENOENT else { throw Failure.system(errno) }
    }

    enum Failure: Error, LocalizedError {
        case installing
        case alreadyRunning
        case system(Int32)

        var errorDescription: String? {
            switch self {
            case .installing: "Insomnia installation or removal is in progress. Launch again when it finishes."
            case .alreadyRunning: "Insomnia is already running for this application data directory."
            case .system(let code): "Could not acquire the Insomnia instance lease: \(String(cString: strerror(code)))"
            }
        }
    }
}
