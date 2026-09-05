import Darwin
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


extension PowerOwnershipTests {
    func testQuitRetriesOwnedSessionDeletionAfterIORecovers() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let blocked = Locked(true)
        let store = h.store
        let clock = h.clock
        let m = SessionManager(paths: h.home.paths, sleepGuard: h.guardFake,
                               processControl: h.procs, backstop: h.backstop, clamshell: { false },
                               clock: { clock.now }, sessionRemover: {
                                   if blocked.value { throw POSIXError(.EACCES) }
                                   try store.deleteSession()
                               })
        await m.start(duration: 3600)
        let original = try XCTUnwrap(try h.store.loadSession())
        let first = await m.prepareToQuit()
        XCTAssertFalse(first)
        XCTAssertEqual(try h.store.loadSession(), original)
        XCTAssertTrue(m.cleanupPending)
        blocked.value = false
        let retry = await m.prepareToQuit()
        XCTAssertTrue(retry)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), .clean)
        XCTAssertFalse(m.cleanupPending)
        XCTAssertFalse(m.cleanupRetryScheduled)
    }

    func testCleanupRetryRearmsAfterRecoveryLeaseTimeout() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let clock = h.clock
        let m = SessionManager(paths: h.home.paths, sleepGuard: h.guardFake,
                               processControl: h.procs, backstop: h.backstop, clamshell: { false },
                               clock: { clock.now }, recoveryLeaseTimeout: .milliseconds(20))
        await m.start(duration: 3600)
        h.guardFake.throwOn = ["disablesleep 0"]
        await m.end(reason: .user)
        XCTAssertTrue(m.cleanupRetryScheduled)
        h.guardFake.throwOn = []
        let fd = Darwin.open(h.home.paths.recoveryLock.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let schedules = h.backstop.scheduled.count
        await m.makeCleanupRetryAction()()
        XCTAssertTrue(m.cleanupPending)
        XCTAssertTrue(m.cleanupRetryScheduled, "a consumed retry must rearm after lock contention")
        XCTAssertEqual(h.backstop.scheduled.count, schedules, "do not mutate the backstop without the lease")
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        await m.makeCleanupRetryAction()()
        XCTAssertFalse(m.cleanupPending)
        XCTAssertFalse(m.cleanupRetryScheduled)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState(), .clean)
    }

    func testSuccessfulStartCancelsPreviousCleanupRetry() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.throwOn = ["disablesleep 0"]
        await m.end(reason: .user)
        XCTAssertTrue(m.cleanupRetryScheduled)
        let queuedRetry = m.makeCleanupRetryAction()
        h.guardFake.throwOn = []
        await m.start(duration: 7200)
        XCTAssertTrue(m.isActive)
        XCTAssertFalse(m.cleanupPending)
        XCTAssertFalse(m.cleanupRetryScheduled)
        let replacement = m.session
        await queuedRetry()
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.session, replacement)
        XCTAssertEqual(try h.store.loadSession(), replacement)
        await m.end(reason: .user)
    }

    func testQuitCanCleanFailedStartBeforeSessionWasPublished() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let blocked = Locked(true)
        let store = h.store
        let clock = h.clock
        h.backstop.failSchedule = true
        let m = SessionManager(paths: h.home.paths, sleepGuard: h.guardFake,
                               processControl: h.procs, backstop: h.backstop, clamshell: { false },
                               clock: { clock.now }, sessionRemover: {
                                   if blocked.value { throw POSIXError(.EACCES) }
                                   try store.deleteSession()
                               })
        await m.start(duration: 3600)
        XCTAssertFalse(m.isActive)
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertTrue(m.cleanupPending)
        blocked.value = false
        h.backstop.failSchedule = false
        let approved = await m.prepareToQuit()
        XCTAssertTrue(approved)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), .clean)
        XCTAssertFalse(m.cleanupPending)
    }

    func testCorruptReplacementStateCannotBypassReconcileOwnershipCheck() async throws {
        for alreadyActive in [false, true] {
            let h = Harness(); defer { h.home.destroy() }
            if !alreadyActive {
                try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
            }
            let m = h.makeManager()
            if alreadyActive { await m.start(duration: 3600) }
            let replacement = Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(7200))
            try h.store.saveSession(replacement)
            let corrupt = Data("{replacement-unreadable".utf8)
            try corrupt.write(to: h.home.paths.stateFile)
            let calls = h.guardFake.calls
            let scheduled = h.backstop.scheduled
            await m.reconcile()
            XCTAssertEqual(try h.store.loadSession(), replacement)
            XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), corrupt)
            XCTAssertEqual(h.guardFake.calls, calls)
            XCTAssertEqual(h.backstop.scheduled, scheduled)
            XCTAssertEqual(h.backstop.clears, 0)
            XCTAssertFalse(m.isActive)
        }
    }

}
