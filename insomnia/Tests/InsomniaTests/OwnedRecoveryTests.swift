import XCTest
@testable import Insomnia

@MainActor
final class OwnedRecoveryTests: XCTestCase {
    func testLegacyPIDIsRetainedWithoutSignaling() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        var state = RuntimeState()
        state.frozenPids = [123]
        try h.store.saveState(state)
        let manager = h.makeManager()
        await manager.restoreAll()
        XCTAssertTrue(h.procs.resumed.isEmpty)
        XCTAssertEqual(try h.store.loadState()?.frozenPids, [123])
    }

    func testLegacyAudioCannotRestoreAnUnidentifiedDefaultDevice() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        var state = RuntimeState()
        state.savedOutputVolume = 0.4
        state.savedMuted = false
        try h.store.saveState(state)
        let manager = h.makeManager()
        await manager.restoreAll()
        XCTAssertTrue(h.audio.applied.isEmpty)
        XCTAssertEqual(try h.store.loadState()?.savedOutputVolume, 0.4)
    }
}

extension OwnedRecoveryTests {
    func testPartialRecoveryPreservesUnknownKeysAndOnlyUnresolvedEntries() throws {
        let h = Harness()
        defer { h.home.destroy() }
        var state = RuntimeState()
        state.frozenPids = [41, 42, 99]
        state.frozenProcesses = [41, 42].map(FakeProcessControl.identity)
        state.dockerFrozen = true
        state.savedOutputDeviceUID = "disconnected"
        state.savedOutputVolume = 0.5
        state.savedMuted = false
        h.procs.failedResumes = [42]
        h.audio.missingDevices = ["disconnected"]
        var original = try JSONSerialization.jsonObject(with: Store.makeEncoder().encode(state)) as! [String: Any]
        original["futurePowerPreference"] = ["enabled": true]
        let file = h.home.root.appendingPathComponent("stage.json")
        try JSONSerialization.data(withJSONObject: original).write(to: file)

        XCTAssertEqual(RecoveryCommand.run(stateFile: file, processes: h.procs, audio: h.audio), 1)
        let data = try Data(contentsOf: file)
        let retained = try Store.makeDecoder().decode(RuntimeState.self, from: data)
        XCTAssertEqual(retained.frozenPids, [42, 99])
        XCTAssertEqual(retained.frozenProcesses.map(\.pid), [42])
        XCTAssertTrue(retained.dockerFrozen)
        XCTAssertEqual(retained.savedOutputDeviceUID, "disconnected")
        XCTAssertEqual(retained.savedOutputVolume, 0.5)
        let dictionary = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dictionary["futurePowerPreference"] as? [String: Bool], ["enabled": true])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFailedJournalWriteReturnsFailureWithoutClearingOriginal() throws {
        let h = Harness()
        defer { h.home.destroy() }
        var state = RuntimeState()
        state.frozenPids = [41]
        state.frozenProcesses = [FakeProcessControl.identity(41)]
        let original = try Store.makeEncoder().encode(state)
        let file = h.home.root.appendingPathComponent("stage.json")
        try original.write(to: file)
        XCTAssertEqual(RecoveryCommand.run(stateFile: file, processes: h.procs, audio: h.audio, write: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }), 1)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testCompletedOwnedRecoveryLeavesPowerIntentsForShell() throws {
        let h = Harness()
        defer { h.home.destroy() }
        var state = RuntimeState()
        state.sleepDisabledByUs = true
        state.lowPowerSetByUs = true
        state.savedOutputDeviceUID = "test-output"
        state.savedOutputVolume = 0.4
        state.savedMuted = true
        let file = h.home.root.appendingPathComponent("stage.json")
        try Store.makeEncoder().encode(state).write(to: file)
        XCTAssertEqual(RecoveryCommand.run(stateFile: file, processes: h.procs, audio: h.audio), 0)
        let restored = try Store.makeDecoder().decode(RuntimeState.self, from: Data(contentsOf: file))
        XCTAssertTrue(restored.sleepDisabledByUs)
        XCTAssertTrue(restored.lowPowerSetByUs)
        XCTAssertFalse(restored.hasUnresolvedOwnedChanges)
        XCTAssertEqual(h.audio.restoredDevices, ["test-output"])
    }

    func testHelperDispatchBypassesGUIInstanceGuardAndDoesNotReacquireJournalLease() throws {
        let home = TempHome()
        defer { home.destroy() }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = package.appendingPathComponent(".build/debug/Insomnia")
        let binary = home.paths.recoveryHelper
        try FileManager.default.copyItem(at: source, to: binary)
        let stage = home.root.appendingPathComponent("stage.json")
        try Data("{}".utf8).write(to: stage)
        let descriptor = open(home.paths.instanceLock.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        try JournalLock.withLock(at: home.paths.recoveryLock) {
            for (arguments, status) in [
                (["--recover-owned", stage.path], Int32(0)),
                (["--validate-recovery-state", stage.path], 0),
                (["--maintenance-protocol"], 0),
                (["--maintenance-uninstall", "--purge"], 1), // Loose helper cannot unregister an app.
                (["--unknown-maintenance"], 2),
                (["--maintenance-uninstall", "--unknown"], 2)
            ] {
                let process = Process()
                process.executableURL = binary
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment.merging(["INSOMNIA_HOME": home.root.path]) { _, new in new }
                process.standardError = Pipe()
                try process.run()
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { process.terminate(); XCTFail("Headless recovery blocked on a GUI or journal lock") }
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, status, arguments.joined(separator: " "))
            }
        }
    }
}
