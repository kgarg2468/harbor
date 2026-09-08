import XCTest
@testable import Insomnia

actor AuditBackstop: BackstopScheduling {
    let gate: AsyncGate
    let blockCall: Int
    var calls = 0
    init(gate: AsyncGate, blockCall: Int) { self.gate = gate; self.blockCall = blockCall }
    func schedule(endsAt: Date) async throws {
        calls += 1
        if calls == blockCall { await gate.wait() }
    }
    func clear() async throws {}
}

actor AuditPowerGuard: SleepGuarding {
    let gate: AsyncGate
    var sleepDisabled = false
    var lowPower = false
    init(gate: AsyncGate) { self.gate = gate }
    func setSleepDisabled(_ disabled: Bool) async throws { sleepDisabled = disabled }
    func isSleepDisabled() async throws -> Bool { sleepDisabled }
    func setLowPowerMode(_ on: Bool) async throws {
        if on { await gate.wait() }
        lowPower = on
    }
}

@MainActor
final class AuditRegressionTests: XCTestCase {
    func testExtendCannotResurrectEndedSession() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let gate = AsyncGate()
        let backstop = AuditBackstop(gate: gate, blockCall: 2)
        let m = SessionManager(paths: h.home.paths, sleepGuard: h.guardFake, processControl: h.procs, backstop: backstop, clock: { h.clock.now })
        await m.start(duration: 3600)
        let pending = Task { await m.extend(by: 3600) }
        await gate.waitUntilStarted()
        await m.end(reason: .user)
        await gate.open()
        await pending.value
        XCTAssertNil(m.session, "ending must invalidate a pending extension")
        XCTAssertNil(try h.store.loadSession(), "an ended session must stay deleted")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        await m.end(reason: .user)
    }

    func testEndDuringStartCannotDisableSleepAfterCleanup() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let gate = AsyncGate()
        let backstop = AuditBackstop(gate: gate, blockCall: 1)
        let m = SessionManager(paths: h.home.paths, sleepGuard: h.guardFake, processControl: h.procs, backstop: backstop, clock: { h.clock.now })
        let pending = Task { await m.start(duration: 3600) }
        await gate.waitUntilStarted()
        await m.end(reason: .quit)
        await gate.open()
        await pending.value
        XCTAssertNil(m.session, "quit/end must invalidate pending start")
        XCTAssertFalse(h.guardFake.sleepDisabled, "sleep cannot be disabled after cleanup")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(m.state.sleepDisabledByUs, "journal was already cleared")
        await m.end(reason: .user)
    }

    func testCountdownPauseDoesNotSurviveNewSession() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        m.pauseCountdown()
        await m.end(reason: .user)
        await m.start(duration: 3600)
        XCTAssertTrue(m.countdownTimerArmed, "new session must redraw its countdown")
        await m.end(reason: .user)
    }

    func testPendingLowPowerCannotApplyAfterEnd() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let gate = AsyncGate()
        let power = AuditPowerGuard(gate: gate)
        let m = SessionManager(paths: h.home.paths, sleepGuard: power, processControl: h.procs, backstop: h.backstop, clock: { h.clock.now })
        await m.start(duration: 3600)
        let pending = Task { await m.setLowPower(true) }
        await gate.waitUntilStarted()
        await m.end(reason: .user)
        await gate.open()
        _ = await pending.value
        let actualLowPower = await power.lowPower
        XCTAssertFalse(actualLowPower, "late enable must be undone after end")
        XCTAssertFalse(m.state.lowPowerSetByUs, "journal was already cleared")
    }

    func testReconcileFailsClosedIfBackstopCannotArm() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        h.backstop.failSchedule = true
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertFalse(h.guardFake.sleepDisabled, "must not disable sleep without a working backstop")
        XCTAssertFalse(m.isActive, "reconcile must fail closed")
        await m.end(reason: .user)
    }

    func testBrowserProfileContainingSpaceSurvivesPsOutput() {
        let raw = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --profile-directory=Profile 1 --user-data-dir=/tmp/Browser Profile"
        XCTAssertEqual(ChromiumFlags.preservedArgs(args: raw), ["--profile-directory=Profile 1", "--user-data-dir=/tmp/Browser Profile"])
    }
}
