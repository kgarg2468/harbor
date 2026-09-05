import CryptoKit
import Darwin
import XCTest
@testable import Insomnia

final class LaunchdBackstopTests: XCTestCase {
    func testPlistWithDeadlineHasCalendarIntervalOneMinuteLater() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let endsAt = cal.date(from: DateComponents(year: 2027, month: 3, day: 9, hour: 23, minute: 59))!
        let d = LaunchdBackstop.plistDictionary(label: "com.insomnia.backstop", scriptPath: "/x/backstop.sh", endsAt: endsAt, calendar: cal)
        XCTAssertEqual(d["Label"] as? String, "com.insomnia.backstop")
        XCTAssertEqual(d["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(d["ProgramArguments"] as? [String], ["/bin/bash", "/x/backstop.sh"])
        let sci = try XCTUnwrap(d["StartCalendarInterval"] as? [String: Int])
        XCTAssertEqual(sci, ["Minute": 0, "Hour": 0, "Day": 10, "Month": 3])
    }

    func testClearedPlistKeepsRunAtLoadOnly() {
        let d = LaunchdBackstop.plistDictionary(label: "l", scriptPath: "/x", endsAt: nil)
        XCTAssertEqual(d["RunAtLoad"] as? Bool, true)
        XCTAssertNil(d["StartCalendarInterval"])
    }

    func testWritePlistSerialises() throws {
        let home = TempHome()
        defer { home.destroy() }
        let b = LaunchdBackstop(paths: home.paths)
        try b.writePlist(endsAt: Date())
        let data = try Data(contentsOf: home.paths.backstopPlist)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(obj?["Label"] as? String, "com.insomnia.backstop")
        XCTAssertEqual((obj?["ProgramArguments"] as? [String])?.last, home.paths.backstopScript.path)
        try b.writePlist(endsAt: nil)
        let data2 = try Data(contentsOf: home.paths.backstopPlist)
        let obj2 = try PropertyListSerialization.propertyList(from: data2, format: nil) as? [String: Any]
        XCTAssertNil(obj2?["StartCalendarInterval"])
    }
}


enum RecoveryHelperFixture {
    static func install(_ paths: Paths) throws {
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: paths.backstopScript)
        let bytes = Data("fixture-recovery-helper".utf8)
        try bytes.write(to: paths.recoveryHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.recoveryHelper.path)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try Data("insomnia-maintenance-v1 \(hash)\n".utf8).write(to: paths.recoveryHelper.appendingPathExtension("protocol"))
    }
}

extension LaunchdBackstopTests {
    func testUnverifiedRecoveryHelperNeverMutatesPlistOrJob() async throws {
        for invalid in ["missing-helper", "missing-marker", "mismatch", "wrong-protocol", "helper-symlink",
                        "marker-symlink", "marker-uppercase", "marker-no-newline", "marker-oversized",
                        "helper-directory", "helper-fifo", "helper-nonexecutable", "helper-oversized",
                        "script-symlink", "script-directory", "script-fifo"] {
            let home = TempHome(); defer { home.destroy() }
            try RecoveryHelperFixture.install(home.paths)
            let marker = home.paths.recoveryHelper.appendingPathExtension("protocol")
            switch invalid {
            case "missing-helper": try FileManager.default.removeItem(at: home.paths.recoveryHelper)
            case "missing-marker": try FileManager.default.removeItem(at: marker)
            case "mismatch": try Data("different-helper".utf8).write(to: home.paths.recoveryHelper)
            case "wrong-protocol": try Data("insomnia-maintenance-v0 invalid\n".utf8).write(to: marker)
            case "helper-symlink", "marker-symlink", "script-symlink":
                let file = invalid == "helper-symlink" ? home.paths.recoveryHelper : (invalid == "marker-symlink" ? marker : home.paths.backstopScript)
                let other = home.root.appendingPathComponent("symlink-target")
                try FileManager.default.moveItem(at: file, to: other)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            case "marker-uppercase":
                let value = try String(contentsOf: marker, encoding: .utf8)
                let hash = value.dropFirst("insomnia-maintenance-v1 ".count).uppercased()
                try Data("insomnia-maintenance-v1 \(hash)".utf8).write(to: marker)
            case "marker-no-newline":
                try Data(Data(contentsOf: marker).dropLast()).write(to: marker)
            case "marker-oversized": try Data(repeating: 65, count: 1024).write(to: marker)
            case "helper-nonexecutable":
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.paths.recoveryHelper.path)
            case "helper-oversized":
                let handle = try FileHandle(forWritingTo: home.paths.recoveryHelper)
                try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
                try handle.close()
            default:
                let file = invalid.hasPrefix("helper") ? home.paths.recoveryHelper : home.paths.backstopScript
                try FileManager.default.removeItem(at: file)
                if invalid.hasSuffix("fifo") { XCTAssertEqual(mkfifo(file.path, 0o600), 0) }
                else { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
            }
            let calls = Locked<[String]>([])
            let backstop = LaunchdBackstop(paths: home.paths, runner: { _, args in
                calls.value.append(args.first ?? "")
                return ShellResult(status: 0, stdout: "", stderr: "")
            })
            try backstop.writePlist(endsAt: Date(timeIntervalSince1970: 1_900_000_000))
            let previous = try Data(contentsOf: home.paths.backstopPlist)
            do {
                try await backstop.schedule(endsAt: Date(timeIntervalSince1970: 1_900_003_600))
                XCTFail("accepted \(invalid)")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: home.paths.backstopPlist), previous, invalid)
            XCTAssertTrue(calls.value.isEmpty, invalid)
        }
    }
    func testVerifiedHelperAllowsScheduleWithInjectedRunner() async throws {
        let home = TempHome(); defer { home.destroy() }
        try RecoveryHelperFixture.install(home.paths)
        let calls = Locked<[String]>([])
        let backstop = LaunchdBackstop(paths: home.paths, runner: { _, args in
            calls.value.append(args.first ?? "")
            return ShellResult(status: 0, stdout: "", stderr: "")
        })
        try await backstop.schedule(endsAt: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(calls.value, ["bootout", "bootstrap"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.backstopPlist.path))
    }

}
