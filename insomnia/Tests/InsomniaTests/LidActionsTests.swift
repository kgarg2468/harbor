import Darwin
import XCTest
@testable import Insomnia

@MainActor
final class LidActionsTests: XCTestCase {
    var h: Harness!
    var freezer: FakeFreezer!

    let processes: [ProcessEntry] = [
        ProcessEntry(pid: 1, ppid: 0),
        ProcessEntry(pid: 100, ppid: 1),
        ProcessEntry(pid: 101, ppid: 100),
        ProcessEntry(pid: 102, ppid: 100),
        ProcessEntry(pid: 400, ppid: 1),
        ProcessEntry(pid: 401, ppid: 400),
    ]
    let apps: [RunningApp] = [
        RunningApp(pid: 100, bundleId: "com.tinyspeck.slackmacgap", name: "Slack"),
        RunningApp(pid: 400, bundleId: "com.docker.docker", name: "Docker"),
    ]

    override func setUp() async throws {
        h = Harness()
        freezer = FakeFreezer(apps: apps, processes: processes, control: h.procs)
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    private func make(dockerIdle: @escaping @Sendable () async throws -> Bool = { true }, mute: Bool = true) async -> (SessionManager, LidActions) {
        let m = h.makeManager()
        m.config.dockerRule = true // These integration tests explicitly opt in.
        m.config.muteOnLidClose = mute
        m.config.freezeList = ["com.tinyspeck.slackmacgap"]
        let docker = DockerRule(freezer: freezer, probe: dockerIdle)
        let actions = LidActions(manager: m, freezer: freezer, docker: docker, audio: h.audio)
        return (m, actions)
    }

    func testCloseJournalsBeforeActing() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        let store = h.store

        // The fake audio's mute sees state.json already holding the saved values.
        let sawSaved = Locked(false)
        h.audio.onMute = {
            let s = (try? store.loadState()) ?? nil
            sawSaved.value = s?.savedOutputVolume == 0.6 && s?.savedMuted == false
        }
        // Each suspend sees its own pids already journaled.
        let sawPids = Locked(true)
        h.procs.onSuspend = { pids in
            let s = (try? store.loadState()) ?? nil
            if !Set(pids).isSubset(of: Set(s?.frozenPids ?? [])) { sawPids.value = false }
        }

        await actions.onClose()

        XCTAssertTrue(sawSaved.value, "mute ran before the journal was written")
        XCTAssertTrue(sawPids.value, "SIGSTOP ran before the pids were journaled")
        XCTAssertEqual(h.audio.mutes, 1)
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102], [400, 401]])
        let s = try XCTUnwrap(try store.loadState())
        XCTAssertEqual(s.frozenPids, [100, 101, 102, 400, 401])
        XCTAssertTrue(s.dockerFrozen)
        XCTAssertEqual(s.savedOutputVolume, 0.6)
        XCTAssertEqual(s.savedMuted, false)
        XCTAssertEqual(m.state, s)
        XCTAssertTrue(m.isActive)
    }

    func testOpenRestoresFromDiskAndClears() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        h.clock.advance(120)

        await actions.onOpen()

        XCTAssertEqual(h.procs.resumed, [[100, 101, 102, 400, 401]])
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(h.audio.applied.first?.volume, 0.6)
        XCTAssertEqual(h.audio.applied.first?.muted, false)
        XCTAssertFalse(h.audio.muted)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenPids, [])
        XCTAssertFalse(s.dockerFrozen)
        XCTAssertNil(s.savedOutputVolume)
        XCTAssertNil(s.savedMuted)
        XCTAssertTrue(s.sleepDisabledByUs)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.remainingText, "58m")
    }

    func testOpenTwiceIsIdempotent() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        await actions.onOpen()
        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed.count, 1)
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(try h.store.loadState()?.frozenPids, [])
    }

    func testOpenWithCleanStateDoesNothing() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed, [])
        XCTAssertEqual(h.audio.applied.count, 0)
    }

    func testNoSessionIsNoop() async throws {
        let (_, actions) = await make()
        await actions.onClose()
        await actions.onOpen()
        XCTAssertEqual(h.procs.suspended, [])
        XCTAssertEqual(h.procs.resumed, [])
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)
    }

    func testMuteOffLeavesAudioAlone() async throws {
        let (m, actions) = await make(mute: false)
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)
        await actions.onOpen()
        XCTAssertEqual(h.audio.applied.count, 0)
    }

    func testDockerWithContainersIsLeftAlone() async throws {
        let (m, actions) = await make(dockerIdle: { false })
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).dockerFrozen)
    }

    func testDockerProbeErrorLeavesDockerAlone() async throws {
        let (m, actions) = await make(dockerIdle: { throw ShellTimeoutError.timedOut(exe: "docker", seconds: 5) })
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).dockerFrozen)
    }

    func testDockerRuleOffSkipsDocker() async throws {
        let (m, actions) = await make()
        m.config.dockerRule = false
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
    }

    func testSessionEndWhileClosedRestoresEverything() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        await m.end(reason: .timer)
        XCTAssertEqual(h.procs.resumed, [[100, 101, 102, 400, 401]])
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        // Lid open afterwards: no session, nothing happens.
        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed.count, 1)
        XCTAssertEqual(h.audio.applied.count, 1)
    }

    func testSessionEndWhileDockerProbeIsSuspendedNeverFreezesDocker() async throws {
        let probe = AsyncGate()
        let (m, actions) = await make(dockerIdle: {
            await probe.wait()
            return true
        })
        await m.start(duration: 3600)
        let close = Task { await actions.onClose() }
        await probe.waitUntilStarted()

        await m.end(reason: .user)
        await probe.open()
        await close.value

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    func testExternalRecoveryPreventsStaleLidSideEffects() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        try h.store.deleteSession(); try h.store.saveState(.clean)
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertEqual(h.procs.suspended, [])
        XCTAssertEqual(try h.store.loadState(), .clean)
        XCTAssertFalse(m.isActive)
    }

    func testMuteAndFreezeHoldLeaseThroughSideEffects() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        let lockPath = h.home.paths.recoveryLock.path
        let excluded = Locked(true)
        let probe: @Sendable () -> Void = {
            let fd = open(lockPath, O_RDWR | O_CLOEXEC)
            defer { _ = close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                excluded.value = false
                _ = flock(fd, LOCK_UN)
            }
        }
        h.audio.onMute = probe
        h.procs.onSuspend = { _ in probe() }
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 1)
        XCTAssertEqual(h.procs.suspended.count, 2)
        XCTAssertTrue(excluded.value)
        await m.end(reason: .user)
    }

    func testBackstopCanRecoverDuringDockerProbeAndPreventsLaterFreeze() async throws {
        let gate = AsyncGate()
        let (m, actions) = await make(dockerIdle: { await gate.wait(); return true })
        await m.start(duration: 3600)
        let close = Task { await actions.onClose() }
        await gate.waitUntilStarted()
        let peer = try JournalLockPeer(paths: h.home.paths, recovery: true); defer { peer.release() }
        try await peer.waitForLease()
        peer.release()
        // Wait for peer release before exercising the stale-session check.
        try await JournalLock.withLease(at: h.home.paths.recoveryLock) {}
        await gate.open(); await close.value
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertEqual(try h.store.loadState(), .clean)
        XCTAssertFalse(m.isActive)
    }

    func testAudioReadFailureSkipsMuteButStillFreezes() async throws {
        let (m, actions) = await make()
        h.audio.throwOnRead = true
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)
        XCTAssertEqual(h.procs.suspended.count, 2)
    }
}

final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: T
    init(_ v: T) { _v = v }
    var value: T {
        get { lock.withLock { _v } }
        set { lock.withLock { _v = newValue } }
    }
}

extension LidActionsTests {
    func testAlreadyStoppedProcessesAreNotJournaledAndFailedStopsAreRemoved() async throws {
        h.procs.stoppedBeforePlanning = [100]
        h.procs.failedSuspends = [101]
        let (manager, actions) = await make(mute: false)
        await manager.start(duration: 3600)
        await actions.onClose()
        let state = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(state.frozenPids.contains(100))
        XCTAssertFalse(state.frozenPids.contains(101))
        XCTAssertFalse(h.procs.suspended.flatMap { $0 }.contains(100))
        XCTAssertEqual(Set(state.frozenPids), Set(state.frozenProcesses.map(\.pid)))
    }

    func testRepeatedCloseKeepsOriginalAudioDeviceOwnership() async throws {
        let (manager, actions) = await make()
        await manager.start(duration: 3600)
        await actions.onClose()
        h.audio.defaultDeviceUID = "new-default"
        await actions.onClose()
        XCTAssertEqual(h.audio.mutedDevices, ["test-output", "test-output"])
        XCTAssertEqual(try h.store.loadState()?.savedOutputDeviceUID, "test-output")
        await actions.onOpen()
        XCTAssertEqual(h.audio.restoredDevices, ["test-output"])
    }

}
