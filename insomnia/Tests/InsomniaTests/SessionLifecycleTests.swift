import XCTest
@testable import Insomnia

@MainActor
final class SessionLifecycleTests: XCTestCase {
    private func finishWhileSuspended(_ m: SessionManager, gate: AsyncGate) async -> Task<Void, Never> {
        let requested = expectation(description: "end requested")
        let end = Task { requested.fulfill(); await m.end(reason: .quit) }
        await fulfillment(of: [requested])
        await gate.open()
        return end
    }

    private func assertEnded(_ m: SessionManager, _ h: Harness, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(m.isActive, file: file, line: line)
        XCTAssertFalse(m.sleepHeld, file: file, line: line)
        XCTAssertFalse(h.guardFake.sleepDisabled, file: file, line: line)
        XCTAssertFalse(h.guardFake.lowPower, file: file, line: line)
        XCTAssertNil(try h.store.loadSession(), file: file, line: line)
        XCTAssertEqual(m.state, .clean, file: file, line: line)
        XCTAssertFalse(m.countdownTimerArmed, file: file, line: line)
        XCTAssertNil(m.scheduledDeadline, file: file, line: line)
    }

    func testEndDuringBackstopArmCannotLeaveUnownedSleepMutation() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let gate = AsyncGate(); h.backstop.scheduleGate = gate
        let m = h.makeManager()
        let start = Task { await m.start(duration: 3600) }
        await gate.waitUntilStarted()
        let end = await finishWhileSuspended(m, gate: gate)
        await start.value; await end.value
        try assertEnded(m, h)
    }

    func testEndWaitsForActualSleepEnableThenRestoresIt() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let gate = AsyncGate(); h.guardFake.sleepGate = gate
        let m = h.makeManager()
        let start = Task { await m.start(duration: 3600) }
        await gate.waitUntilStarted()
        let end = await finishWhileSuspended(m, gate: gate)
        await start.value; await end.value
        try assertEnded(m, h)
    }

    func testExtensionCannotResurrectEndedSession() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        let gate = AsyncGate(); h.backstop.scheduleGate = gate
        let extending = Task { await m.extend(by: 3600) }
        await gate.waitUntilStarted()
        let end = await finishWhileSuspended(m, gate: gate)
        await extending.value; await end.value
        try assertEnded(m, h)
    }

    func testReconcileCannotReactivateAfterEnd() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        let gate = AsyncGate(); h.backstop.scheduleGate = gate
        let m = h.makeManager()
        let reconcile = Task { await m.reconcile() }
        await gate.waitUntilStarted()
        let end = await finishWhileSuspended(m, gate: gate)
        await reconcile.value; await end.value
        try assertEnded(m, h)
    }

    func testInFlightLowPowerDoesNotPublishSuccessAfterEndRequest() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        let gate = AsyncGate(); h.guardFake.lowPowerGate = gate
        let power = Task { await m.setLowPower(true) }
        await gate.waitUntilStarted()
        let end = await finishWhileSuspended(m, gate: gate)
        let changed = await power.value
        await end.value
        XCTAssertFalse(changed)
        try assertEnded(m, h)
    }

    func testLowPowerCannotBeEnabledWithoutActiveSession() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        let changed = await m.setLowPower(true)
        XCTAssertFalse(changed)
        XCTAssertFalse(h.guardFake.lowPower)
        XCTAssertFalse(m.state.lowPowerSetByUs)
    }

    func testCountdownPauseIsResetFromLidForNewSession() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        m.pauseCountdown(); await m.end(reason: .user)
        await m.start(duration: 3600)
        XCTAssertTrue(m.countdownTimerArmed)
        await m.end(reason: .user)
        h.clamshell.closed = true
        await m.start(duration: 3600)
        XCTAssertFalse(m.countdownTimerArmed)
        await m.end(reason: .user)
    }

    func testReconcileScheduleFailureRestoresExistingOwnership() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        var state = RuntimeState.clean
        state.sleepDisabledByUs = true; state.lowPowerSetByUs = true
        try h.store.saveState(state)
        h.guardFake.sleepDisabled = true
        try await h.guardFake.setLowPowerMode(true)
        h.backstop.failSchedule = true
        let m = h.makeManager(); await m.reconcile()
        try assertEnded(m, h)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"))
        XCTAssertNotNil(m.lastError)
    }

    func testReconcileJournalFailureNeverEnablesSleepOrActivates() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        let m = h.makeManager()
        try FileManager.default.createDirectory(at: h.home.paths.stateFile, withIntermediateDirectories: false)
        await m.reconcile()
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"))
        XCTAssertNil(try h.store.loadSession())
        XCTAssertNotNil(m.lastError)
    }

    func testReconcileSleepFailureDoesNotPublishActiveSession() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        h.guardFake.throwOn = ["disablesleep 1"]
        let m = h.makeManager(); await m.reconcile()
        try assertEnded(m, h)
        XCTAssertNotNil(m.lastError)
    }

    func testReconcileArmsRecoveryBeforeEnablingSleep() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        let gate = AsyncGate(); h.backstop.scheduleGate = gate
        let m = h.makeManager()
        let reconcile = Task { await m.reconcile() }
        await gate.waitUntilStarted()
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(m.sleepHeld)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        // Deliberately inspect bytes while the owner is suspended; Store access
        // from this independent task must refuse the held transaction lease.
        let bytes = try Data(contentsOf: h.home.paths.stateFile)
        XCTAssertTrue(try Store.makeDecoder().decode(RuntimeState.self, from: bytes).sleepDisabledByUs)
        await gate.open(); await reconcile.value
        XCTAssertTrue(m.sleepHeld)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        await m.end(reason: .user)
    }

    func testFailedReconcileKeepsRecoveryIntentWithoutClaimingSleepHeld() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        h.guardFake.throwOn = ["disablesleep 1", "disablesleep 0"]
        let m = h.makeManager(); await m.reconcile()
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(m.sleepHeld)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertTrue(m.state.sleepDisabledByUs)
        XCTAssertEqual(h.backstop.clears, 0)
    }

    func testExtensionWriteFailureEndsSafely() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        let sessionFile = h.home.paths.sessionFile
        h.backstop.onSchedule = {
            try? FileManager.default.removeItem(at: sessionFile)
            try? FileManager.default.createDirectory(at: sessionFile, withIntermediateDirectories: false)
        }
        await m.extend(by: 3600)
        try assertEnded(m, h)
        XCTAssertEqual(h.backstop.clears, 1)
        XCTAssertNotNil(m.lastError)
    }


    func testStartRefusesToOverwriteUnrestoredOwnership() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        h.guardFake.throwOn = ["disablesleep 0"]
        await m.end(reason: .user)
        let scheduleCount = h.backstop.scheduled.count
        await m.start(duration: 7200)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.backstop.scheduled.count, scheduleCount)
        XCTAssertTrue(m.state.sleepDisabledByUs)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertNotNil(m.lastError)
        h.guardFake.throwOn = []
        await m.end(reason: .user)
    }

    func testStartRestoresOldOwnershipBeforeArmingNewSession() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        var oldState = RuntimeState.clean; oldState.lowPowerSetByUs = true
        try h.store.saveState(oldState)
        try await h.guardFake.setLowPowerMode(true)
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertFalse(h.guardFake.lowPower)
        XCTAssertFalse(m.state.lowPowerSetByUs)
        XCTAssertEqual(h.guardFake.calls, ["lowpowermode 1", "lowpowermode 0", "disablesleep 1"])
        await m.end(reason: .user)
    }

    func testIncompleteCleanupReportsRecoveryFailure() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        h.guardFake.throwOn = ["disablesleep 0"]
        await m.end(reason: .user)
        XCTAssertEqual(h.notifier.posts.last?.title, "Cleanup incomplete")
        XCTAssertFalse(h.notifier.posts.last?.body.contains("back to normal") ?? true)
        XCTAssertEqual(h.backstop.clears, 0)
    }

    func testPartiallyAppliedLowPowerFailureIsCompensated() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        h.guardFake.throwAfterApplying = ["lowpowermode 1"]
        let changed = await m.setLowPower(true)
        XCTAssertFalse(changed)
        XCTAssertFalse(h.guardFake.lowPower)
        XCTAssertFalse(m.state.lowPowerSetByUs)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertEqual(h.guardFake.calls.suffix(2), ["lowpowermode 1", "lowpowermode 0"])
        await m.end(reason: .user)
    }

    func testLowPowerCompensationFailureRetainsOwnershipForRetry() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        h.guardFake.throwAfterApplying = ["lowpowermode 1"]
        h.guardFake.throwOn = ["lowpowermode 0"]
        let changed = await m.setLowPower(true)
        XCTAssertFalse(changed)
        XCTAssertTrue(h.guardFake.lowPower)
        XCTAssertTrue(m.state.lowPowerSetByUs)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        await m.end(reason: .user)
        XCTAssertEqual(h.notifier.posts.last?.title, "Cleanup incomplete")
        XCTAssertEqual(h.backstop.clears, 0)
        h.guardFake.throwOn = []
        await m.end(reason: .user)
        try assertEnded(m, h)
    }


    func testCleanupJournalFailureKeepsOwnershipAndReportsIncomplete() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        let stateFile = h.home.paths.stateFile
        h.guardFake.onSleepChange = { disabled in
            guard !disabled else { return }
            try? FileManager.default.removeItem(at: stateFile)
            try? FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)
        }
        await m.end(reason: .user)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertTrue(m.state.sleepDisabledByUs, "uncommitted cleanup must keep recovery intent")
        XCTAssertEqual(h.notifier.posts.last?.title, "Cleanup incomplete")
        XCTAssertEqual(h.backstop.clears, 0)
        await m.start(duration: 3600)
        XCTAssertFalse(m.isActive)
        h.guardFake.onSleepChange = nil
        try FileManager.default.removeItem(at: stateFile)
        await m.end(reason: .user)
        try assertEnded(m, h)
    }

    func testExternalRecoveryCannotBeResurrectedByExtensionOrLowPower() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        try h.store.deleteSession(); try h.store.saveState(.clean)
        h.guardFake.sleepDisabled = false
        let scheduled = h.backstop.scheduled.count
        await m.extend(by: 3600)
        let changed = await m.setLowPower(true)
        XCTAssertFalse(changed)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), .clean)
        XCTAssertEqual(h.backstop.scheduled.count, scheduled)
        XCTAssertFalse(h.guardFake.lowPower)
    }

    func testStaleEndDoesNotDeleteReplacementOrRestoreItsChanges() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        let replacement = Session(startedAt: h.clock.now.addingTimeInterval(1), endsAt: h.clock.now.addingTimeInterval(7200))
        try h.store.saveSession(replacement)
        var replacementState = RuntimeState.clean; replacementState.lowPowerSetByUs = true
        try h.store.saveState(replacementState)
        let calls = h.guardFake.calls
        await m.end(reason: .user)
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(try h.store.loadSession(), replacement)
        XCTAssertEqual(try h.store.loadState(), replacementState)
        XCTAssertEqual(h.guardFake.calls, calls)
        XCTAssertEqual(h.backstop.clears, 0)
    }

    func testSecondManagerStartDoesNotOverwriteValidSession() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let first = h.makeManager(); await first.start(duration: 3600)
        let original = try h.store.loadSession()
        let second = h.makeManager(); await second.start(duration: 7200)
        XCTAssertFalse(second.isActive)
        XCTAssertEqual(try h.store.loadSession(), original)
        XCTAssertEqual(h.backstop.scheduled.count, 1)
        await first.end(reason: .user)
    }

    func testFractionalClockSessionRetainsDurableOwnership() async throws {
        let h = Harness(now: Date(timeIntervalSince1970: 1_800_000_000.123)); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        await m.extend(by: 600)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.session?.extensions, [600])
        let changed = await m.setLowPower(true)
        XCTAssertTrue(changed)
        await m.end(reason: .user)
        try assertEnded(m, h)
    }

    func testBackstopWaitsForWholeStartThenExtensionRereadsRecovery() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        let gate = AsyncGate(); h.guardFake.sleepGate = gate
        let start = Task { await m.start(duration: 3600) }
        await gate.waitUntilStarted()
        let peer = try JournalLockPeer(paths: h.home.paths, recovery: true); defer { peer.release() }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(peer.hasLease, "backstop must wait even after journal writes finish")
        await gate.open(); await start.value
        try await peer.waitForLease()
        let extending = Task { await m.extend(by: 600) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(h.backstop.scheduled.count, 1)
        peer.release(); await extending.value
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), .clean)
        XCTAssertEqual(h.backstop.scheduled.count, 1)
    }

    func testNewStartWaitsForRecoveryBeforeReadingOwnership() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        var old = RuntimeState.clean; old.lowPowerSetByUs = true
        try h.store.saveState(old)
        let peer = try JournalLockPeer(paths: h.home.paths, recovery: true); defer { peer.release() }
        try await peer.waitForLease()
        let start = Task { await m.start(duration: 3600) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.guardFake.calls, [])
        peer.release(); await start.value
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertFalse(m.state.lowPowerSetByUs)
        await m.end(reason: .user)
    }

    func testBackstopWaitsForLowPowerSideEffect() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        let gate = AsyncGate(); h.guardFake.lowPowerGate = gate
        let power = Task { await m.setLowPower(true) }
        await gate.waitUntilStarted()
        let peer = try JournalLockPeer(paths: h.home.paths); defer { peer.release() }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(peer.hasLease)
        await gate.open()
        let changed = await power.value
        XCTAssertTrue(changed)
        try await peer.waitForLease()
        peer.release()
        await m.end(reason: .user)
        try assertEnded(m, h)
    }

    func testLowPowerRereadsRecoveryWithoutAnEarlierMutation() async throws {
        for turnOn in [true, false] {
            let h = Harness(); defer { h.home.destroy() }
            let m = h.makeManager(); await m.start(duration: 3600)
            if !turnOn { _ = await m.setLowPower(true) }
            try h.store.deleteSession(); try h.store.saveState(.clean)
            let calls = h.guardFake.calls
            let changed = await m.setLowPower(turnOn)
            XCTAssertFalse(changed)
            XCTAssertFalse(m.isActive)
            XCTAssertEqual(h.guardFake.calls, calls)
            XCTAssertEqual(try h.store.loadState(), .clean)
        }
    }

    func testIdenticalTimesReplacementCannotBeExtendedOrEndedByStaleManager() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); await m.start(duration: 3600)
        let original = try XCTUnwrap(try h.store.loadSession())
        let replacement = Session(startedAt: original.startedAt, endsAt: original.endsAt, extensions: original.extensions)
        try h.store.saveSession(replacement)
        let calls = h.guardFake.calls
        await m.extend(by: 600)
        await m.end(reason: .user)
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(try h.store.loadSession(), replacement)
        XCTAssertEqual(h.backstop.scheduled.count, 1)
        XCTAssertEqual(h.backstop.clears, 0)
        XCTAssertEqual(h.guardFake.calls, calls)
    }

}
