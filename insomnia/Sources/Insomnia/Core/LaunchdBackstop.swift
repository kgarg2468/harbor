import CryptoKit
import Darwin
import Foundation

/// Keeps the launchd agent that runs backstop.sh in sync with the session
/// deadline, so sleep is restored even if Insomnia is gone.
protocol BackstopScheduling: Sendable {
    /// Fire once at (just after) `endsAt`, and at every load.
    func schedule(endsAt: Date) async throws
    /// Drop the calendar trigger, keep RunAtLoad.
    func clear() async throws
}

struct BackstopError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct LaunchdBackstop: BackstopScheduling {
    typealias Runner = @Sendable (String, [String]) async throws -> ShellResult
    private let runner: Runner
    private let environment: [String: String]
    private let recoveryHelper: URL

    private struct UnloadFailure: LocalizedError {
        var errorDescription: String? { "Could not confirm removal of the previous recovery job" }
    }

    static let launchctl = "/bin/launchctl"

    let plistURL: URL
    let scriptPath: String
    let label: String
    let uid: uid_t

    init(paths: Paths, label: String = Paths.backstopLabel, uid: uid_t = getuid(), runner: @escaping Runner = { try await Shell.run($0, $1, timeout: 15) }) {
        self.runner = runner
        self.recoveryHelper = paths.recoveryHelper
        self.environment = paths == .standard ? [:] : [Paths.environmentKey: paths.appSupport.path]
        self.plistURL = paths.backstopPlist
        self.scriptPath = paths.backstopScript.path
        self.label = label
        self.uid = uid
    }

    func schedule(endsAt: Date) async throws {
        try verifyRecoveryInstallation()
        try await replace(endsAt: endsAt)
    }

    func clear() async throws {
        try await replace(endsAt: nil)
    }

    /// Validate before replacing either the durable plist or the loaded job.
    /// The caller's recovery lease also excludes installer replacement while a
    /// session is being armed; inode snapshots catch changes during this read.
    private func verifyRecoveryInstallation() throws {
        let invalid = BackstopError(message: "Recovery installation is missing or invalid; run scripts/install.sh before starting a session")
        func openRegular(_ url: URL, maximum: Int) throws -> (FileHandle, stat) {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw invalid }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size > 0, info.st_size <= maximum else {
                _ = close(fd)
                throw invalid
            }
            return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), info)
        }
        func unchanged(_ url: URL, _ handle: FileHandle, _ initial: stat) throws {
            var current = stat(), named = stat()
            guard fstat(handle.fileDescriptor, &current) == 0, lstat(url.path, &named) == 0,
                  named.st_mode & S_IFMT == S_IFREG,
                  current.st_dev == initial.st_dev, current.st_ino == initial.st_ino,
                  named.st_dev == initial.st_dev, named.st_ino == initial.st_ino,
                  current.st_size == initial.st_size,
                  current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
                  current.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
                  current.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else { throw invalid }
        }
        let scriptURL = URL(fileURLWithPath: scriptPath)
        let (script, scriptInfo) = try openRegular(scriptURL, maximum: 1024 * 1024)
        defer { try? script.close() }
        let maximumHelperBytes = 64 * 1024 * 1024
        let (helper, helperInfo) = try openRegular(recoveryHelper, maximum: maximumHelperBytes)
        defer { try? helper.close() }
        guard access(recoveryHelper.path, X_OK) == 0 else { throw invalid }
        let markerURL = recoveryHelper.appendingPathExtension("protocol")
        let prefix = "insomnia-maintenance-v1 "
        let markerBytes = prefix.utf8.count + 64 + 1
        let (marker, markerInfo) = try openRegular(markerURL, maximum: markerBytes)
        defer { try? marker.close() }
        let recorded = try marker.read(upToCount: markerBytes + 1) ?? Data()
        var digest = SHA256()
        var count = 0
        while let chunk = try helper.read(upToCount: 64 * 1024), !chunk.isEmpty {
            count += chunk.count
            guard count <= maximumHelperBytes else { throw invalid }
            digest.update(data: chunk)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == helperInfo.st_size,
              recorded == Data("\(prefix)\(hash)\n".utf8) else { throw invalid }
        try unchanged(scriptURL, script, scriptInfo)
        try unchanged(recoveryHelper, helper, helperInfo)
        try unchanged(markerURL, marker, markerInfo)
    }

    // MARK: Plist

    /// Pure builder, testable without launchd. When `endsAt` is given the
    /// calendar interval is one minute after it so the session timer always
    /// gets first go.
    static func plistDictionary(label: String, scriptPath: String, endsAt: Date?, calendar: Calendar = .current) -> [String: Any] {
        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", scriptPath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 60,
        ]
        if let endsAt {
            let fire = endsAt.addingTimeInterval(60)
            let c = calendar.dateComponents([.minute, .hour, .day, .month], from: fire)
            dict["StartCalendarInterval"] = [
                "Minute": c.minute ?? 0,
                "Hour": c.hour ?? 0,
                "Day": c.day ?? 1,
                "Month": c.month ?? 1,
            ]
        }
        return dict
    }

    func writePlist(endsAt: Date?) throws {
        var dict = Self.plistDictionary(label: label, scriptPath: scriptPath, endsAt: endsAt)
        if !environment.isEmpty { dict["EnvironmentVariables"] = environment }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    /// Restore both disk and loaded job if replacing a deadline fails. Callers
    /// must still fail closed when rollback itself cannot restore protection.
    private func replace(endsAt: Date?) async throws {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw BackstopError(message: "backstop.sh not installed at \(scriptPath); run scripts/install.sh")
        }
        let previous = FileManager.default.fileExists(atPath: plistURL.path)
            ? try Data(contentsOf: plistURL) : nil
        try writePlist(endsAt: endsAt)
        do {
            try await reload()
        } catch {
            let failure = error
            do {
                if let previous {
                    try previous.write(to: plistURL, options: .atomic)
                    if !(failure is UnloadFailure) { try await reload() }
                } else {
                    if !(failure is UnloadFailure) {
                        _ = try await runner(Self.launchctl, ["bootout", "gui/\(uid)", plistURL.path])
                    }
                    try FileManager.default.removeItem(at: plistURL)
                }
            } catch {
                throw BackstopError(message: "\(failure.localizedDescription); recovery rollback also failed: \(error.localizedDescription)")
            }
            throw failure
        }
    }

    // MARK: launchctl

    /// Confirm bootout or absence before bootstrap. RunAtLoad means the
    /// script runs immediately on every reload; it is a no-op while the
    /// session on disk is valid.
    ///
    /// Throws when the agent cannot be loaded: a session must never start
    /// without a backstop, so callers treat this as a hard failure.
    private func reload() async throws {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw BackstopError(message: "backstop.sh not installed at \(scriptPath); run scripts/install.sh")
        }
        let domain = "gui/\(uid)"
        let unloaded = (try? await runner(Self.launchctl, ["bootout", domain, plistURL.path]))?.succeeded == true
        if !unloaded {
            let probe = try? await runner(Self.launchctl, ["print", "\(domain)/\(label)"])
            guard probe?.status == 113 else { throw UnloadFailure() }
        }
        let r = try await runner(Self.launchctl, ["bootstrap", domain, plistURL.path])
        if !r.succeeded {
            throw BackstopError(message: "launchctl bootstrap failed (\(r.status)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
