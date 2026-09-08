import XCTest
@testable import Insomnia

@MainActor
final class EarlyRootValidationTests: XCTestCase {
    func testSharedRootIsRefusedBeforeAnyInstanceOrJournalLockIsCreated() async throws {
        let home = TempHome(); defer { home.destroy() }
        let unrelated = home.root.appendingPathComponent("unrelated.txt")
        try Data("shared content".utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.root.path)
        XCTAssertThrowsError(try AppInstanceLease(paths: home.paths,
            installerGuard: home.root.appendingPathComponent("unused-installer-guard")))
        XCTAssertThrowsError(try JournalLock.withLock(at: home.paths.recoveryLock) {
            XCTFail("Shared root must not enter a synchronous transaction")
        })
        do {
            try await JournalLock.withLease(at: home.paths.recoveryLock) {
                XCTFail("Shared root must not enter an asynchronous transaction")
            }
            XCTFail("Shared root must refuse the asynchronous lease")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.root.path), ["unrelated.txt"])
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "shared content")
        let mode = try FileManager.default.attributesOfItem(atPath: home.root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
    }

    func testPrivateAndNewRootsAllowBothLeases() async throws {
        let home = TempHome(); defer { home.destroy() }
        for paths in [home.paths, Paths(root: home.root.appendingPathComponent("new-root"))] {
            let instance = try AppInstanceLease(paths: paths,
                installerGuard: home.root.appendingPathComponent("unused-installer-guard"))
            try JournalLock.withLock(at: paths.recoveryLock) {}
            try await JournalLock.withLease(at: paths.recoveryLock) {}
            withExtendedLifetime(instance) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: paths.instanceLock.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: paths.recoveryLock.path))
            }
            let mode = try FileManager.default.attributesOfItem(atPath: paths.appSupport.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o700)
        }
    }
}
