import Foundation

/// The only two things Insomnia ever does as root, both through the four
/// sudoers-allowed pmset commands written by install.sh.
protocol SleepGuarding: Sendable {
    func setSleepDisabled(_ disabled: Bool) async throws
    func isSleepDisabled() async throws -> Bool
    func setLowPowerMode(_ on: Bool) async throws
    func batteryLowPowerMode() async throws -> Bool
}

struct SleepGuardError: Error, LocalizedError, Sendable {
    let command: String
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        var msg = "`\(command)` failed with status \(status)"
        if !detail.isEmpty { msg += ": \(detail)" }
        if detail.contains("password") || detail.contains("sudo") {
            msg += " (run scripts/install.sh to install /etc/sudoers.d/insomnia)"
        }
        return msg
    }
}

/// `sudo -n pmset …`. Never prompts; if the sudoers rule is missing the call
/// fails fast with a readable error instead of hanging on a password prompt.
struct PmsetSleepGuard: SleepGuarding {
    typealias Runner = @Sendable (String, [String]) async throws -> ShellResult
    private let runner: Runner
    init(runner: @escaping Runner = { try await Shell.run($0, $1) }) { self.runner = runner }

    static let sudo = "/usr/bin/sudo"
    static let pmset = "/usr/bin/pmset"

    func setSleepDisabled(_ disabled: Bool) async throws {
        try await sudoPmset(["-a", "disablesleep", disabled ? "1" : "0"])
    }

    func setLowPowerMode(_ on: Bool) async throws {
        try await sudoPmset(["-b", "lowpowermode", on ? "1" : "0"])
    }

    func isSleepDisabled() async throws -> Bool {
        let r = try await runner(Self.pmset, ["-g"])
        guard r.succeeded else {
            throw SleepGuardError(command: "pmset -g", status: r.status, stderr: r.stderr)
        }
        return try Self.parseSleepDisabled(r.stdout)
    }

    func batteryLowPowerMode() async throws -> Bool {
        let r = try await runner(Self.pmset, ["-g", "custom"])
        guard r.succeeded else {
            throw SleepGuardError(command: "pmset -g custom", status: r.status, stderr: r.stderr)
        }
        return try Self.parseBatteryLowPowerMode(r.stdout)
    }

    /// Missing, duplicated, or malformed values are unknown, never implicit off.
    static func parseSleepDisabled(_ output: String) throws -> Bool {
        try booleanValue("SleepDisabled", in: output)
    }

    static func parseBatteryLowPowerMode(_ output: String) throws -> Bool {
        var batterySections = 0
        var inBattery = false
        var lines: [String] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                inBattery = line.lowercased() == "battery power:"
                if inBattery { batterySections += 1 }
            } else if inBattery { lines.append(line) }
        }
        guard batterySections == 1 else { throw unknown("battery power section") }
        return try booleanValue("lowpowermode", in: lines.joined(separator: "\n"))
    }

    private static func booleanValue(_ key: String, in output: String) throws -> Bool {
        let matches = output.split(whereSeparator: \.isNewline).map {
            $0.split(whereSeparator: \.isWhitespace)
        }.filter { $0.first == Substring(key) }
        guard matches.count == 1, matches[0].count == 2,
              matches[0][1] == "0" || matches[0][1] == "1" else { throw unknown(key) }
        return matches[0][1] == "1"
    }

    private static func unknown(_ field: String) -> SleepGuardError {
        SleepGuardError(command: "read power preferences", status: -1,
                        stderr: "Missing or ambiguous \(field); power settings were not changed")
    }

    private func sudoPmset(_ args: [String]) async throws {
        let full = [Self.pmset] + args
        let r = try await runner(Self.sudo, ["-n"] + full)
        guard r.succeeded else {
            throw SleepGuardError(command: "sudo -n \(full.joined(separator: " "))", status: r.status, stderr: r.stderr)
        }
    }
}
