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

    static let launchctl = "/bin/launchctl"

    let plistURL: URL
    let scriptPath: String
    let label: String
    let uid: uid_t

    init(paths: Paths, label: String = Paths.backstopLabel, uid: uid_t = getuid(), runner: @escaping Runner = { try await Shell.run($0, $1, timeout: 15) }) {
        self.runner = runner
        self.environment = paths == .standard ? [:] : [Paths.environmentKey: paths.appSupport.path]
        self.plistURL = paths.backstopPlist
        self.scriptPath = paths.backstopScript.path
        self.label = label
        self.uid = uid
    }

    func schedule(endsAt: Date) async throws {
        try await replace(endsAt: endsAt)
    }

    func clear() async throws {
        try await replace(endsAt: nil)
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
                    try await reload()
                } else {
                    _ = try await runner(Self.launchctl, ["bootout", "gui/\(uid)", plistURL.path])
                    try FileManager.default.removeItem(at: plistURL)
                }
            } catch {
                throw BackstopError(message: "\(failure.localizedDescription); recovery rollback also failed: \(error.localizedDescription)")
            }
            throw failure
        }
    }

    // MARK: launchctl

    /// bootout (ignored if not loaded) then bootstrap. RunAtLoad means the
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
        _ = try await runner(Self.launchctl, ["bootout", domain, plistURL.path])
        let r = try await runner(Self.launchctl, ["bootstrap", domain, plistURL.path])
        if !r.succeeded {
            throw BackstopError(message: "launchctl bootstrap failed (\(r.status)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
