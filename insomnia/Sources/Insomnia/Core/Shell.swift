import Darwin
import Foundation

struct ShellResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

enum ShellError: Error, LocalizedError {
    case launchFailed(exe: String, underlying: String)
    case outputLimitExceeded

    var errorDescription: String? {
        switch self {
        case .outputLimitExceeded: return "Command output exceeded the 8 MiB limit"
        case let .launchFailed(exe, underlying):
            return "could not launch \(exe): \(underlying)"
        }
    }
}

/// Argument-array execution with a private process group and bounded pipe reads.
/// The timeout includes descendants holding inherited output descriptors open.
enum Shell {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    static func run(_ exe: String, _ args: [String]) async throws -> ShellResult {
        try await run(exe, args, timeout: 30)
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> ShellResult {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try execute(exe, args, timeout: timeout, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func execute(_ exe: String, _ args: [String], timeout: TimeInterval, cancellation: Cancellation) throws -> ShellResult {
        if cancellation.isCancelled { throw CancellationError() }
        guard timeout.isFinite, timeout > 0 else { throw ShellTimeoutError.timedOut(exe: exe, seconds: timeout) }
        func check(_ result: Int32) throws {
            guard result == 0 else { throw ShellError.launchFailed(exe: exe, underlying: String(cString: strerror(result))) }
        }
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw ShellError.launchFailed(exe: exe, underlying: String(cString: strerror(errno))) }
        defer { for fd in out where fd >= 0 { close(fd) } }
        guard pipe(&err) == 0 else { throw ShellError.launchFailed(exe: exe, underlying: String(cString: strerror(errno))) }
        defer { for fd in err where fd >= 0 { close(fd) } }
        for fd in out + err { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ShellError.launchFailed(exe: exe, underlying: String(cString: strerror(errno))) } }
        for fd in [out[0], err[0]] {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw ShellError.launchFailed(exe: exe, underlying: String(cString: strerror(errno))) }
        }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO))
        for fd in out + err { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // Set the group atomically at spawn; parent-side setpgid races exec.
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var defaults: sigset_t = 0
        sigfillset(&defaults)
        var mask: sigset_t = 0
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + env { free(p) } }
        var pid: pid_t = 0
        let launched = argv.withUnsafeBufferPointer { arguments in
            env.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, exe, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
            }
        }
        try check(launched)
        close(out[1]); out[1] = -1
        close(err[1]); err[1] = -1
        var reaped = false
        var ownsChild = true
        var exited = false
        // Also covers output errors. Reap asynchronously if the kernel has not
        // delivered exit yet; cleanup must not defeat the caller's deadline.
        defer {
            if ownsChild && !reaped {
                kill(-pid, SIGKILL)
                let child = pid
                DispatchQueue.global().async { var status: Int32 = 0; while waitpid(child, &status, 0) < 0 && errno == EINTR {} }
            }
        }
        var stdout = Data(), stderr = Data()
        var outEOF = false, errEOF = false
        var status: Int32 = 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var failure: (any Error)?
        var killAt: TimeInterval?
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil {
                if cancellation.isCancelled { failure = CancellationError() }
                else if now >= deadline { failure = ShellTimeoutError.timedOut(exe: exe, seconds: timeout) }
                if failure != nil { kill(-pid, SIGTERM); killAt = now + 0.2 }
            }
            if let killAt, now >= killAt {
                kill(-pid, SIGKILL)
                throw failure!
            }
            do {
                if !outEOF { outEOF = try drain(out[0], into: &stdout, otherBytes: stderr.count) }
                if !errEOF { errEOF = try drain(err[0], into: &stderr, otherBytes: stdout.count) }
            } catch {
                // The root can have exited while a descendant still writes.
                kill(-pid, SIGKILL)
                throw error
            }
            if !exited {
                var info = siginfo_t()
                let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if result == 0, info.si_pid == pid { exited = true }
                else if result < 0, errno != EINTR {
                    if errno == ECHILD { ownsChild = false }
                    throw ShellError.launchFailed(exe: exe, underlying: String(cString: strerror(errno)))
                }
            }
            if exited && outEOF && errEOF {
                if let failure { throw failure }
                // Keep the leader unreaped until no group signals can follow.
                // Its reserved PID prevents an escaped descendant from allowing
                // another process group to reuse the identifier during cleanup.
                var result: pid_t
                repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
                guard result == pid else {
                    if errno == ECHILD { ownsChild = false }
                    throw ShellError.launchFailed(exe: exe, underlying: String(cString: strerror(errno)))
                }
                reaped = true
                let exitStatus = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                return ShellResult(status: exitStatus, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
            }
            // Polling happens on the worker queue, never on the app's main actor.
            usleep(10_000)
        }
    }

    private static func drain(_ fd: Int32, into data: inout Data, otherBytes: Int) throws -> Bool {
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Bound each drain too: a continuously writing child must not starve
        // cancellation, the deadline, or the other output stream.
        for _ in 0..<32 {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return false }
                throw ShellError.launchFailed(exe: "output pipe", underlying: String(cString: strerror(errno)))
            }
            guard data.count + otherBytes + count <= 8 * 1024 * 1024 else { throw ShellError.outputLimitExceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
        return false
    }
}
