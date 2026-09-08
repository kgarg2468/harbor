import XCTest
@testable import Insomnia

@MainActor
final class AppInstanceLeaseTests: XCTestCase {
    func testSecondInstanceIsRefusedAndReleasePreservesLockInode() throws {
        let home = TempHome(); defer { home.destroy() }
        let installer = home.root.appendingPathComponent("installer.lock")
        var first: AppInstanceLease? = try AppInstanceLease(paths: home.paths, installerGuard: installer)
        let inode = try FileManager.default.attributesOfItem(atPath: home.paths.instanceLock.path)[.systemFileNumber] as? NSNumber
        XCTAssertThrowsError(try AppInstanceLease(paths: home.paths, installerGuard: installer))
        XCTAssertNotNil(first)
        first = nil
        let next = try AppInstanceLease(paths: home.paths, installerGuard: installer)
        try withExtendedLifetime(next) {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: home.paths.instanceLock.path)[.systemFileNumber] as? NSNumber, inode)
        }
    }

    func testInstallerGuardRefusesStartupBeforeCreatingInstanceFile() throws {
        let home = TempHome(); defer { home.destroy() }
        let installer = home.root.appendingPathComponent("installer.lock")
        try FileManager.default.createDirectory(at: installer, withIntermediateDirectories: false)
        XCTAssertThrowsError(try AppInstanceLease(paths: home.paths, installerGuard: installer)) { error in
            XCTAssertTrue(error.localizedDescription.contains("install"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.instanceLock.path))
        try FileManager.default.removeItem(at: installer)
        let lease = try AppInstanceLease(paths: home.paths, installerGuard: installer)
        withExtendedLifetime(lease) {}
    }

    func testInstanceLeaseExcludesRealLockfPeerUntilReleased() throws {
        let home = TempHome(); defer { home.destroy() }
        let installer = home.root.appendingPathComponent("installer.lock")
        var lease: AppInstanceLease? = try AppInstanceLease(paths: home.paths, installerGuard: installer)
        func probe() throws -> Int32 {
            let peer = Process()
            peer.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            peer.arguments = ["-k", "-t", "0", home.paths.instanceLock.path, "/usr/bin/true"]
            peer.standardOutput = FileHandle.nullDevice
            peer.standardError = FileHandle.nullDevice
            try peer.run(); peer.waitUntilExit()
            return peer.terminationStatus
        }
        XCTAssertNotNil(lease)
        XCTAssertNotEqual(try probe(), 0)
        lease = nil
        XCTAssertEqual(try probe(), 0)
    }

    func testUnwritableInstanceLockFailsClosed() throws {
        let home = TempHome(); defer { home.destroy() }
        let installer = home.root.appendingPathComponent("installer.lock")
        try FileManager.default.createDirectory(at: home.paths.instanceLock, withIntermediateDirectories: false)
        XCTAssertThrowsError(try AppInstanceLease(paths: home.paths, installerGuard: installer))
    }
}
