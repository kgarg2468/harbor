import Darwin
import Foundation

/// Matches backstop.sh's `lockf -k`: BSD flock on one permanent inode.
/// Never unlink this file, including when releasing a lease.
enum JournalLock {
    @TaskLocal private static var held: Lease?

    private final class Lease: @unchecked Sendable {
        let path: String
        let descriptor: Int32
        private let mutex = NSLock()
        private var active = true

        init(path: String, descriptor: Int32) {
            self.path = path
            self.descriptor = descriptor
        }

        var isActive: Bool { mutex.withLock { active } }

        func release() {
            mutex.withLock {
                guard active else { return }
                active = false
                _ = flock(descriptor, LOCK_UN)
                _ = Darwin.close(descriptor)
            }
        }
    }

    private static func openLock(_ url: URL) throws -> Int32 {
        try PrivateFiles.directory(url.deletingLastPathComponent())
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.system(errno) }
        return fd
    }

    private static func tryAcquire(_ fd: Int32) throws -> Bool {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
        guard errno == EWOULDBLOCK || errno == EINTR else { throw Failure.system(errno) }
        return false
    }

    /// Synchronous journal operations never block the main actor. Nested Store
    /// calls reuse the transaction lease, but inherited tokens expire on release.
    static func withLock<T>(at url: URL, _ operation: () throws -> T) throws -> T {
        if let held, held.path == url.path, held.isActive { return try operation() }
        let fd = try openLock(url)
        let lease = Lease(path: url.path, descriptor: fd)
        defer { lease.release() }
        guard try tryAcquire(fd) else { throw Failure.busy }
        return try $held.withValue(lease, operation: operation)
    }

    /// Lifecycle calls hold the lease across async side effects. Polling lets the
    /// main actor process end requests while another process owns recovery.
    @MainActor
    static func withLease<T>(at url: URL, timeout: Duration = .seconds(30), _ operation: () async throws -> T) async throws -> T {
        let fd = try openLock(url)
        let lease = Lease(path: url.path, descriptor: fd)
        defer { lease.release() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while try !tryAcquire(fd) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.busy }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        return try await $held.withValue(lease, operation: operation)
    }

    enum Failure: Error, LocalizedError {
        case busy
        case system(Int32)
        var errorDescription: String? {
            switch self {
            case .busy: "Recovery journal is busy; retry the operation."
            case .system(let code): "Recovery journal lock failed: \(String(cString: strerror(code)))"
            }
        }
    }
}
