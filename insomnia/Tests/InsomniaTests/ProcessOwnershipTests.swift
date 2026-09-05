import Darwin
import XCTest
@testable import Insomnia

final class ProcessOwnershipTests: XCTestCase {
    private func identity(_ pid: Int32 = 41, start: UInt64 = 100, boot: String = "boot-a") -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTimeMicroseconds: start, bootID: boot)
    }

    func testReusedPIDOtherBootAndAlreadyRunningAreResolvedWithoutSignal() {
        let owned = identity()
        for current in [ProcessSignalState(identity: identity(start: 101), ppid: 1, stopped: true),
                        ProcessSignalState(identity: identity(boot: "boot-b"), ppid: 1, stopped: true),
                        ProcessSignalState(identity: owned, ppid: 1, stopped: false)] {
            let control = SignalProcessControl(stateLookup: { _ in .found(current) },
                                               send: { _, _ in XCTFail("Must not signal another identity or an unstopped process"); return 0 })
            XCTAssertTrue(control.resume(processes: [owned]).isEmpty)
        }
    }

    func testResumeRetainsOnlyRetryableFailuresAndInvalidOwnership() {
        let owned = identity()
        let current = ProcessSignalState(identity: owned, ppid: 1, stopped: true)
        for (error, remaining) in [(Int32(0), false), (ESRCH, false), (EPERM, true)] {
            let control = SignalProcessControl(stateLookup: { _ in .found(current) }, send: { pid, signal in
                XCTAssertEqual(pid, owned.pid); XCTAssertEqual(signal, SIGCONT); return error
            })
            XCTAssertEqual(control.resume(processes: [owned]), remaining ? [owned] : [])
        }
        let unavailable = SignalProcessControl(stateLookup: { _ in .unavailable }, send: { _, _ in XCTFail(); return 0 })
        XCTAssertEqual(unavailable.resume(processes: [owned]), [owned])
        let exited = SignalProcessControl(stateLookup: { _ in .exited }, send: { _, _ in XCTFail(); return 0 })
        XCTAssertTrue(exited.resume(processes: [owned]).isEmpty)
        let invalid = identity(0)
        XCTAssertEqual(exited.resume(processes: [invalid]), [invalid])
    }

    func testSuspendRechecksIdentityAndStoppedStateAfterJournalPreparation() {
        let owned = identity()
        let current = Locked(ProcessSignalState(identity: owned, ppid: 1, stopped: false))
        let control = SignalProcessControl(stateLookup: { _ in .found(current.value) },
                                           send: { _, _ in XCTFail("Changed process must not be stopped"); return 0 })
        XCTAssertEqual(control.prepareSuspend(processes: [owned], expectedParents: [41: 1]), [owned])
        current.value = ProcessSignalState(identity: identity(start: 101), ppid: 1, stopped: false)
        XCTAssertTrue(control.suspend(processes: [owned], expectedParents: [41: 1]).isEmpty)
        current.value = ProcessSignalState(identity: owned, ppid: 1, stopped: true)
        XCTAssertTrue(control.prepareSuspend(processes: [owned], expectedParents: [41: 1]).isEmpty)
        XCTAssertTrue(control.suspend(processes: [owned], expectedParents: [41: 1]).isEmpty)
    }

    func testKernelBirthTimeMatchesTreeSnapshotForOurOwnChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        guard case let .found(current) = SignalProcessControl.kernelState(pid: child.processIdentifier) else {
            return XCTFail("Own child must have readable kernel identity")
        }
        let snapshot = try XCTUnwrap(Freezer.processSnapshot().first { $0.pid == child.processIdentifier })
        XCTAssertEqual(snapshot.identity, current.identity)
        XCTAssertEqual(current.ppid, getpid())
        XCTAssertTrue(current.identity.isValid)
        child.terminate()
        child.waitUntilExit()
        guard case .exited = SignalProcessControl.kernelState(pid: child.processIdentifier) else {
            return XCTFail("Exited own child must not leave permanently retryable ownership")
        }
    }
}
