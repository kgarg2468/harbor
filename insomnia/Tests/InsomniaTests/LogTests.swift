import Darwin
import XCTest
@testable import Insomnia

final class LogTests: XCTestCase {
    func testDynamicDiagnosticsAreNotPersisted() throws {
        let home = TempHome(); defer { home.destroy() }
        let privateSSID = "PRIVATE_SSID"
        let privatePath = "/Users/PRIVATE_USER/project"
        Log.append(level: "info", "joining hotspot \(privateSSID)", paths: home.paths)
        Log.append(level: "error", "failed: \(privatePath)", paths: home.paths)
        let text = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertFalse(text.contains(privateSSID))
        XCTAssertFalse(text.contains(privatePath))
        XCTAssertTrue(text.contains("joining hotspot"))
        XCTAssertTrue(text.contains("failed:"))
    }

    func testRuntimeStringDiagnosticsAreNotPersisted() throws {
        let home = TempHome(); defer { home.destroy() }
        let message = "failed with PRIVATE_USER /Users/PRIVATE_USER/project"
        Log.append(level: "error", message, paths: home.paths)
        let text = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_USER"))
    }
    func testLegacyDiagnosticsAreArchivedPrivatelyOnceWithoutRemovingHandoffHistory() throws {
        let home = TempHome(); defer { home.destroy() }
        try home.paths.createDirectories()
        try Data("old PRIVATE_SSID\n".utf8).write(to: home.paths.logFile)
        try Data("older PRIVATE_PATH\n".utf8).write(to: home.paths.logFile.appendingPathExtension("1"))
        let history = "2027-01-15T08:02:10Z outage start=2027-01-15T08:00:00Z end=2027-01-15T08:02:10Z gap=130s\n"
        try Data(history.utf8).write(to: home.paths.handoffsLog)
        Log.append(level: "info", "first safe diagnostic", paths: home.paths)
        Log.append(level: "info", "second safe diagnostic", paths: home.paths)
        let log = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertFalse(log.contains("PRIVATE"))
        XCTAssertTrue(log.contains("first safe diagnostic"))
        XCTAssertTrue(log.contains("second safe diagnostic"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.logFile.appendingPathExtension("1").path))
        XCTAssertEqual(try String(contentsOf: home.paths.handoffsLog, encoding: .utf8), history)
        let legacy = home.paths.logs.appendingPathComponent("legacy-diagnostics")
        let archived = try FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
        XCTAssertEqual(archived.count, 2)
        let oldContent = try archived.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(oldContent.contains("PRIVATE_SSID"))
        XCTAssertTrue(oldContent.contains("PRIVATE_PATH"))
        for file in archived + [home.paths.handoffsLog] {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: legacy.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    func testRotationKeepsBoundedWholeRecordsAndPrivateModes() throws {
        let home = TempHome(); defer { home.destroy() }
        let url = home.paths.handoffsLog
        for index in 0..<100 {
            try JournalLock.withLock(at: home.paths.recoveryLock) {
                try PrivateFiles.appendRecord("outage-record-\(index)", to: url, limit: 100)
            }
        }
        for file in [url, url.appendingPathExtension("1")] {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, 100)
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("outage-record-") })
            XCTAssertEqual(data.last, 10)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("outage-record-99\n"))
        let mode = try FileManager.default.attributesOfItem(atPath: home.paths.logs.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    func testOversizedHistoricalLogKeepsOnlyCompleteTailRecords() throws {
        let home = TempHome(); defer { home.destroy() }
        let url = home.paths.handoffsLog
        try PrivateFiles.write(Data((0..<100).map { "record-\($0)\n" }.joined().utf8), to: url)
        try PrivateFiles.appendRecord("record-100", to: url, limit: 100)
        let previous = try String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)
        XCTAssertLessThanOrEqual(previous.utf8.count, 100)
        XCTAssertTrue(previous.split(separator: "\n").allSatisfy { $0.hasPrefix("record-") })
        XCTAssertTrue(previous.hasSuffix("record-99\n"))
    }

    func testAppendReusesLifecycleLeaseAndSkipsExternalContention() throws {
        let home = TempHome(); defer { home.destroy() }
        try JournalLock.withLock(at: home.paths.recoveryLock) {
            Log.append(level: "info", "inside lifecycle", paths: home.paths)
        }
        let before = try Data(contentsOf: home.paths.logFile)
        let fd = open(home.paths.recoveryLock.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = flock(fd, LOCK_UN); _ = close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        Log.append(level: "info", "must skip contention", paths: home.paths)
        XCTAssertEqual(try Data(contentsOf: home.paths.logFile), before)
    }

    func testPrivateHandleHasRestrictedModeBeforeFirstMetadataWrite() throws {
        let home = TempHome(); defer { home.destroy() }
        let url = home.root.appendingPathComponent("new/nested/metadata.json")
        let handle = try PrivateFiles.handle(url, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { try? handle.close() }
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        for directory in [url.deletingLastPathComponent(), home.root.appendingPathComponent("new")] {
            let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o700)
        }
        try handle.write(contentsOf: Data("PRIVATE_METADATA".utf8))
    }

    func testOversizedArchiveIsBoundedEvenWhenCurrentLogDoesNotRotate() throws {
        let home = TempHome(); defer { home.destroy() }
        let url = home.paths.handoffsLog
        let archive = url.appendingPathExtension("1")
        try PrivateFiles.write(Data((0..<100).map { "record-\($0)\n" }.joined().utf8), to: archive)
        try PrivateFiles.appendRecord("record-100", to: url, limit: 100)
        let previous = try String(contentsOf: archive, encoding: .utf8)
        XCTAssertLessThanOrEqual(previous.utf8.count, 100)
        XCTAssertTrue(previous.hasSuffix("record-99\n"))
        XCTAssertTrue(previous.split(separator: "\n").allSatisfy { $0.hasPrefix("record-") })
    }

}
