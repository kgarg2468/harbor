import XCTest
@testable import Insomnia

@MainActor
final class NetworkCancellationTests: XCTestCase {
    func testStopDuringFirstPanePreventsSecondPaneAndPublication() async {
        let home = TempHome()
        defer { home.destroy() }
        let gate = AsyncGate()
        let calls = Locked<[String]>([])
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date())
        var config = Config()
        config.tmuxTargets = ["first", "second"]
        let network = NetworkFailover(paths: home.paths, nudge: TmuxNudge { target in
            calls.value.append(target)
            await gate.wait()
            return true
        }, notifier: notifier, clock: { clock.now }) { config }
        var recovered = false
        network.onRecovered = { _ in recovered = true }
        await network.simulate(satisfied: false)
        clock.advance(130)
        let task = Task { await network.simulate(satisfied: true) }
        await gate.waitUntilStarted()
        network.stop()
        await gate.open()
        await task.value
        XCTAssertEqual(calls.value, ["first"])
        XCTAssertTrue(notifier.posts.isEmpty)
        XCTAssertFalse(recovered)
        XCTAssertNil(network.lastGap)
    }

    func testCancelledTmuxTaskDoesNotSendToNextPane() async {
        let gate = AsyncGate()
        let calls = Locked<[String]>([])
        let nudge = TmuxNudge { target in
            calls.value.append(target)
            await gate.wait()
            return true
        }
        let task = Task { await nudge.nudge(targets: ["first", "second"]) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.open()
        _ = await task.value
        XCTAssertEqual(calls.value, ["first"])
    }
}

private struct GatedHotspotJoiner: HotspotJoining {
    let gate: AsyncGate
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        await gate.wait()
        return true
    }
}

extension NetworkCancellationTests {
    func testStopDuringJoinDoesNotRearmRetry() async throws {
        let home = TempHome()
        defer { home.destroy() }
        let gate = AsyncGate()
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "fixture")
        let clock = FakeClock(Date())
        var config = Config()
        config.hotspotSSID = "Phone"
        let network = NetworkFailover(paths: home.paths, keychain: keychain,
            hotspotJoiner: GatedHotspotJoiner(gate: gate), notifier: RecordingNotifier(),
            wifiInterface: "en0", clock: { clock.now }) { config }
        await network.simulate(satisfied: false)
        clock.advance(5)
        let task = network.fireTimer()
        await gate.waitUntilStarted()
        network.stop()
        await gate.open()
        await task?.value
        XCTAssertFalse(network.hasScheduledRetry)
        XCTAssertFalse(network.machine.inOutage)
        await network.simulate(satisfied: false)
        XCTAssertFalse(network.hasScheduledRetry)
    }

    func testRecoveryDuringJoinDoesNotRearmRetry() async throws {
        let home = TempHome()
        defer { home.destroy() }
        let gate = AsyncGate()
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "fixture")
        let clock = FakeClock(Date())
        var config = Config()
        config.hotspotSSID = "Phone"
        let network = NetworkFailover(paths: home.paths, keychain: keychain,
            hotspotJoiner: GatedHotspotJoiner(gate: gate), notifier: RecordingNotifier(),
            wifiInterface: "en0", clock: { clock.now }) { config }
        await network.simulate(satisfied: false)
        clock.advance(5)
        let task = network.fireTimer()
        await gate.waitUntilStarted()
        await network.simulate(satisfied: true)
        await gate.open()
        await task?.value
        XCTAssertFalse(network.hasScheduledRetry)
        XCTAssertFalse(network.machine.inOutage)
        network.stop()
    }
}
