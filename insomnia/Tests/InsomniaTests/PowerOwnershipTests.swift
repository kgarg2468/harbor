import XCTest
@testable import Insomnia

@MainActor
final class PowerOwnershipTests: XCTestCase {
    func testAlreadyDisabledSleepIsNotClaimedOrCleared() async throws {
        let h = Harness(); defer { h.home.destroy() }
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertFalse(m.state.sleepDisabledByUs)
        await m.end(reason: .user)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 0"))
    }

    func testAlreadyEnabledBatteryLowPowerIsNotClaimedOrCleared() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try await h.guardFake.setLowPowerMode(true)
        let m = h.makeManager()
        await m.start(duration: 3600)
        let changed = await m.setLowPower(true)
        XCTAssertFalse(changed)
        XCTAssertFalse(m.state.lowPowerSetByUs)
        await m.end(reason: .user)
        XCTAssertTrue(h.guardFake.lowPower)
    }

    func testUnknownSleepReadPreventsOwnershipAndEnable() async throws {
        let h = Harness(); defer { h.home.destroy() }
        h.guardFake.throwOn = ["pmset -g"]
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"))
        XCTAssertNil(try h.store.loadSession())
        XCTAssertNotNil(m.lastError)
    }

    func testCorruptStateDuringEndIsKeptAndDoesNotClearBackstop() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: h.home.paths.stateFile)
        await m.end(reason: .quit)
        XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), corrupt)
        XCTAssertEqual(h.backstop.clears, 0)
        XCTAssertEqual(h.notifier.posts.last?.title, "Cleanup incomplete")
        XCTAssertNotNil(m.lastError)
    }

    func testCorruptStateAtLaunchDoesNotClearUnownedSleep() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: h.home.paths.stateFile)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), corrupt)
        XCTAssertNotNil(m.lastError)
    }

    func testFailedScheduleAndRestoreAttemptIndependentRecoveryAgain() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        let attempts = Locked(0)
        h.backstop.onSchedule = { attempts.value += 1 }
        h.backstop.failSchedule = true
        h.guardFake.throwOn = ["disablesleep 0"]
        await m.extend(by: 3600)
        XCTAssertGreaterThanOrEqual(attempts.value, 2)
        XCTAssertTrue(m.state.sleepDisabledByUs)
        XCTAssertNotNil(m.lastError)
    }
}

extension PowerOwnershipTests {
    func testNewPowerSnapshotsAreDurableBeforeChangesAndClearedAfterRestore() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let recorded = Locked<Bool?>(nil)
        let store = h.store
        h.guardFake.onSleepChange = { disabled in
            if disabled { recorded.value = (try? store.loadState())?.originalSleepDisabled }
        }
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertEqual(recorded.value, false)
        _ = await m.setLowPower(true)
        XCTAssertEqual(try h.store.loadState()?.originalBatteryLowPowerMode, false)
        await m.end(reason: .user)
        XCTAssertEqual(try h.store.loadState(), .clean)
    }

    func testRecordedTruePreferencesRestoreExactlyAndLegacyFlagsRestoreOff() async throws {
        for original in [true, false] {
            let h = Harness(); defer { h.home.destroy() }
            var state = RuntimeState.clean
            state.sleepDisabledByUs = true
            state.lowPowerSetByUs = true
            if original {
                state.originalSleepDisabled = true
                state.originalBatteryLowPowerMode = true
            }
            try h.store.saveState(state)
            let m = h.makeManager()
            await m.end(reason: .user)
            XCTAssertEqual(h.guardFake.sleepDisabled, original)
            XCTAssertEqual(h.guardFake.lowPower, original)
            XCTAssertEqual(try h.store.loadState(), .clean)
        }
    }

    func testUnknownBatteryReadDoesNotEnableOrClaimLowPower() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.throwOn = ["pmset -g custom"]
        let changed = await m.setLowPower(true)
        XCTAssertFalse(changed)
        XCTAssertFalse(h.guardFake.lowPower)
        XCTAssertFalse(m.state.lowPowerSetByUs)
        XCTAssertNil(m.state.originalBatteryLowPowerMode)
        XCTAssertNotNil(m.lastError)
        await m.end(reason: .user)
    }

    func testQuitRefusesFailedCleanupEvenWhenRetryBackstopIsArmed() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.throwOn = ["disablesleep 0"]
        let first = await m.prepareToQuit()
        XCTAssertFalse(first)
        XCTAssertTrue(m.cleanupPending)
        XCTAssertTrue(m.backstopArmed)
        XCTAssertTrue(m.cleanupRetryScheduled)
        XCTAssertTrue(m.lastError?.contains("Quit cancelled") == true)
        h.guardFake.throwOn = []
        let retry = await m.prepareToQuit()
        XCTAssertTrue(retry)
        XCTAssertFalse(m.cleanupPending)
        XCTAssertFalse(m.cleanupRetryScheduled)
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    func testQuitLeaseFailureDoesNotApproveExitFromCleanMemory() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        let gate = AsyncGate()
        let held = Task {
            try await JournalLock.withLease(at: h.home.paths.recoveryLock) {
                var state = RuntimeState.clean; state.sleepDisabledByUs = true
                try h.store.saveState(state)
                h.guardFake.sleepDisabled = true
                await gate.wait()
            }
        }
        await gate.waitUntilStarted()
        XCTAssertEqual(m.state, .clean)
        let quit = Task { await m.prepareToQuit() }
        try await Task.sleep(for: .milliseconds(60))
        quit.cancel()
        let approved = await quit.value
        XCTAssertFalse(approved)
        XCTAssertTrue(m.cleanupPending)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(h.backstop.clears, 0)
        await gate.open(); try await held.value
        let retry = await m.prepareToQuit()
        XCTAssertTrue(retry)
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    func testCorruptStateWithCleanMemoryRefusesQuit() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try Data("{broken".utf8).write(to: h.home.paths.stateFile)
        let m = h.makeManager()
        let approved = await m.prepareToQuit()
        XCTAssertFalse(approved)
        XCTAssertTrue(m.cleanupPending)
        XCTAssertEqual(h.backstop.clears, 0)
    }

    func testSnapshotOnlyOwnershipSurvivesDecodeAndRestores() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let bytes = Data("{\"originalSleepDisabled\":true,\"originalBatteryLowPowerMode\":true}".utf8)
        let state = try Store.makeDecoder().decode(RuntimeState.self, from: bytes)
        XCTAssertTrue(state.isDirty)
        try h.store.saveState(state)
        let m = h.makeManager()
        await m.end(reason: .user)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertTrue(h.guardFake.lowPower)
        XCTAssertEqual(try h.store.loadState(), .clean)
    }
}

extension PowerOwnershipTests {
    func testQuitBeforeStartupReconcileRestoresCapturedSession() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        var state = RuntimeState.clean; state.sleepDisabledByUs = true
        try h.store.saveState(state)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        let approved = await m.prepareToQuit()
        XCTAssertTrue(approved)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertNil(try h.store.loadSession())
    }

    func testQuitBeforeStartupDoesNotDeleteReplacedSession() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        var state = RuntimeState.clean; state.sleepDisabledByUs = true
        try h.store.saveState(state)
        let m = h.makeManager()
        let replacement = Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(7200))
        try h.store.saveSession(replacement)
        let approved = await m.prepareToQuit()
        XCTAssertFalse(approved)
        XCTAssertEqual(try h.store.loadSession(), replacement)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 0"))
    }
}
