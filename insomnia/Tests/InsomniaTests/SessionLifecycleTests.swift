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
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
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

}
