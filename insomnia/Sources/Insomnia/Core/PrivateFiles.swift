import Darwin
import Foundation

/// App-owned directories and files are private before their first content write.
/// Only the known default app directories may have shared permissions repaired.
/// Existing relocation directories must already be private; symlinks are refused.
enum PrivateFiles {
    static let maximumLogBytes = 256 * 1024

    static func directory(_ url: URL, ownedDirectories: [URL] = [Paths.standard.appSupport, Paths.standard.logs]) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw failure() }
            let parent = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) { try directory(parent, ownedDirectories: ownedDirectories) }
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw failure() }
        }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { _ = close(fd) }
        guard fstat(fd, &info) == 0 else { throw failure() }
        let path = url.standardizedFileURL.path
        let mayRepair = ownedDirectories.contains { owned in
            let root = owned.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
        guard info.st_uid == geteuid(), mayRepair || info.st_mode & 0o077 == 0 else {
            throw DirectoryPrivacyError(path: path)
        }
        guard fchmod(fd, 0o700) == 0 else { throw failure() }
    }

    static func handle(_ url: URL, flags: Int32) throws -> FileHandle {
        try directory(url.deletingLastPathComponent())
        // Reject special files below without blocking while opening a FIFO.
        let fd = open(url.path, flags | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              fchmod(fd, 0o600) == 0 else {
            let error = failure()
            _ = close(fd)
            throw error
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func write(_ data: Data, to url: URL, exclusive: Bool = false) throws {
        let h = try handle(url, flags: O_WRONLY | O_CREAT | (exclusive ? O_EXCL : 0))
        defer { try? h.close() }
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: data)
    }

    /// Call under the recovery lease. Keep one bounded archive and rotate only
    /// whole records, including when an older installation left an oversized log.
    static func appendRecord(_ line: String, to url: URL, limit: Int = maximumLogBytes) throws {
        let archive = url.appendingPathExtension("1")
        if FileManager.default.fileExists(atPath: archive.path) {
            let previous = try handle(archive, flags: O_RDONLY)
            defer { try? previous.close() }
            if try previous.seekToEnd() > UInt64(limit) {
                try write(retainedRecords(previous, limit: limit), to: archive)
            }
        }
        let record = Data((line + "\n").utf8)
        guard record.count <= limit else { throw POSIXError(.EFBIG) }
        let h = try handle(url, flags: O_RDWR | O_CREAT | O_APPEND)
        defer { try? h.close() }
        let size = try h.seekToEnd()
        if size > 0, size + UInt64(record.count) > UInt64(limit) {
            try write(retainedRecords(h, limit: limit), to: archive)
            try h.truncate(atOffset: 0)
        }
        try h.write(contentsOf: record)
    }

    private static func retainedRecords(_ h: FileHandle, limit: Int) throws -> Data {
        let size = try h.seekToEnd()
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try h.seek(toOffset: start)
        var tail = try h.readToEnd() ?? Data()
        if start > 0 {
            guard let first = tail.firstIndex(of: 10) else { return Data() }
            tail = Data(tail.suffix(from: tail.index(after: first)))
        }
        // A historical crash may have left an unfinished final record.
        guard let last = tail.lastIndex(of: 10) else { return Data() }
        return Data(tail.prefix(through: last))
    }

    private static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private struct DirectoryPrivacyError: LocalizedError {
        let path: String
        var errorDescription: String? {
            "Refusing non-private directory \(path). Use a dedicated directory owned by your account with mode 0700 for INSOMNIA_HOME."
        }
    }
}
