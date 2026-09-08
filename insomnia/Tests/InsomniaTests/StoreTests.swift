import Darwin
import XCTest
@testable import Insomnia

final class StoreTests: XCTestCase {
    var home: TempHome!
    var store: Store!

    override func setUp() {
        home = TempHome()
        store = Store(paths: home.paths)
    }

    override func tearDown() {
        home.destroy()
    }

    func testMissingFileReturnsNil() throws {
        XCTAssertNil(try store.loadSession())
        XCTAssertNil(try store.loadState())
        XCTAssertNil(try store.loadConfig())
    }

    func testSessionRoundTrip() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(3600), extensions: [600, 1200])
        try store.saveSession(s)
        XCTAssertEqual(try store.loadSession(), s)
    }

    func testStateRoundTripPreservesOptionals() throws {
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.frozenPids = [12, 34]
        st.savedOutputVolume = 0.6
        st.savedMuted = false
        try store.saveState(st)
        XCTAssertEqual(try store.loadState(), st)
    }

    func testDatesAreISO8601ForBackstopScript() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveSession(Session(startedAt: t0, endsAt: t0))
        let text = try String(contentsOf: home.paths.sessionFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"endsAt\" : \"2027-01-15T08:00:00Z\""), text)
    }

    func testAtomicWriteLeavesNoTempFile() throws {
        try store.saveState(RuntimeState())
        try store.saveState(RuntimeState())
        let names = try FileManager.default.contentsOfDirectory(atPath: home.paths.appSupport.path)
        XCTAssertEqual(names.filter { $0.contains(".tmp-") }, [])
        XCTAssertTrue(names.contains("state.json"))
    }

    func testOverwriteReplacesContent() throws {
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try store.saveState(st)
        try store.saveState(RuntimeState())
        XCTAssertEqual(try store.loadState(), RuntimeState())
    }

    func testRemoveMissingIsNotAnError() throws {
        XCTAssertNoThrow(try store.deleteSession())
    }

    func testStateDecodesWithMissingKeys() throws {
        let data = Data(#"{"sleepDisabledByUs": true}"#.utf8)
        let st = try Store.makeDecoder().decode(RuntimeState.self, from: data)
        XCTAssertTrue(st.sleepDisabledByUs)
        XCTAssertEqual(st.frozenPids, [])
        XCTAssertNil(st.savedOutputVolume)
    }

    func testPathsFromEnvironment() {
        let p = Paths.fromEnvironment(["INSOMNIA_HOME": "/tmp/x"])
        XCTAssertEqual(p.sessionFile.path, "/tmp/x/session.json")
        XCTAssertEqual(p.logFile.path, "/tmp/x/Logs/insomnia.log")
        XCTAssertEqual(p.backstopPlist.path, "/tmp/x/LaunchAgents/com.insomnia.backstop.plist")
        let std = Paths.fromEnvironment([:])
        XCTAssertTrue(std.sessionFile.path.hasSuffix("/Library/Application Support/Insomnia/session.json"))
        XCTAssertTrue(std.backstopPlist.path.hasSuffix("/Library/LaunchAgents/com.insomnia.backstop.plist"))
    }
    func testEveryJournalAccessHonorsExternalFlock() throws {
        let fd = open(home.paths.recoveryLock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = flock(fd, LOCK_UN); _ = close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.loadSession())
        XCTAssertThrowsError(try store.loadState())
        XCTAssertThrowsError(try store.saveState(.clean))
        XCTAssertThrowsError(try store.saveSession(Session(startedAt: Date(), endsAt: Date())))
        XCTAssertThrowsError(try store.deleteSession())
    }

    func testMetadataFilesAndOwnedDirectoryArePrivate() throws {
        try store.saveConfig(Config())
        try store.saveState(.clean)
        try store.saveSession(Session(startedAt: Date(), endsAt: Date()))
        for file in [home.paths.configFile, home.paths.stateFile, home.paths.sessionFile] {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: home.paths.appSupport.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    func testSharedRelocationRootIsRefusedWithoutChangingItsContentsOrPermissions() throws {
        let unrelated = home.root.appendingPathComponent("unrelated.txt")
        try Data("shared content".utf8).write(to: unrelated)
        try Store.makeEncoder().encode(Config()).write(to: home.paths.configFile)
        try Data("session fixture".utf8).write(to: home.paths.sessionFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.root.path)
        let before = try FileManager.default.contentsOfDirectory(atPath: home.root.path).sorted()
        XCTAssertThrowsError(try home.paths.createDirectories())
        XCTAssertThrowsError(try store.saveState(.clean))
        XCTAssertThrowsError(try store.loadConfig())
        XCTAssertThrowsError(try store.deleteSession())
        Log.append(level: "info", "shared root must remain untouched", paths: home.paths)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.root.path).sorted(), before)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "shared content")
        let mode = try FileManager.default.attributesOfItem(atPath: home.root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
    }

    func testExistingPrivateRelocationRootIsAccepted() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.root.path)
        try home.paths.createDirectories()
        try store.saveConfig(Config())
        XCTAssertEqual(try store.loadConfig(), Config())
    }

    func testKnownOwnedDirectoryRepairDoesNotIncludePrefixSiblings() throws {
        // Inject the owned-directory policy so the real Library is never touched.
        let owned = home.root.appendingPathComponent("Insomnia")
        let nested = owned.appendingPathComponent("legacy-diagnostics")
        let sibling = home.root.appendingPathComponent("Insomnia-shared")
        for directory in [owned, nested, sibling] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        try PrivateFiles.directory(owned, ownedDirectories: [owned])
        try PrivateFiles.directory(nested, ownedDirectories: [owned])
        XCTAssertThrowsError(try PrivateFiles.directory(sibling, ownedDirectories: [owned]))
        for directory in [owned, nested] {
            let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o700)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: sibling.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
    }

    func testDirectoryCreationLeavesSharedLaunchAgentsPermissionsAlone() throws {
        try FileManager.default.createDirectory(at: home.paths.launchAgents, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.paths.launchAgents.path)
        try home.paths.createDirectories()
        let mode = try FileManager.default.attributesOfItem(atPath: home.paths.launchAgents.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
    }

    func testReadingLegacyMetadataTightensModeAndRefusesSymlinkTargets() throws {
        try store.saveConfig(Config())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.paths.configFile.path)
        XCTAssertNotNil(try store.loadConfig())
        let mode = try FileManager.default.attributesOfItem(atPath: home.paths.configFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let outside = home.root.appendingPathComponent("other-file")
        try Data("PRIVATE_EXTERNAL_CONTENT".utf8).write(to: outside)
        try FileManager.default.removeItem(at: home.paths.configFile)
        try FileManager.default.createSymbolicLink(at: home.paths.configFile, withDestinationURL: outside)
        XCTAssertThrowsError(try store.loadConfig())
        try store.saveConfig(Config())
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "PRIVATE_EXTERNAL_CONTENT")
        XCTAssertNotNil(try store.loadConfig())
    }

}
