import CoreLocation
import XCTest
@testable import Insomnia

final class IntegrationWiringTests: XCTestCase {
    @MainActor
    func testInitialLidActionsWaitForLowPowerLease() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.muteOnLidClose = true
        manager.config.dockerRule = false
        manager.config.freezeList = ["org.example.fixture"]
        let freezer = FakeFreezer(apps: [RunningApp(pid: 100, bundleId: "org.example.fixture", name: "Fixture")],
                                  processes: [ProcessEntry(pid: 100, ppid: 1)], control: h.procs)
        let actions = LidActions(manager: manager, freezer: freezer,
                                 docker: DockerRule(freezer: freezer, probe: { false }), audio: h.audio)
        let services = AppServices(paths: h.home.paths, notifier: h.notifier, audio: h.audio,
                                   processControl: h.procs,
                                   locationPermission: LocationPermission(authorizationStatus: .authorizedAlways))
        await manager.start(duration: 3600)
        services.beginSession(for: manager)
        let gate = AsyncGate()
        h.guardFake.lowPowerGate = gate
        let floors = FloorRuleDriver(manager: manager, notifier: h.notifier)
        let initialFloor = Task { await floors.run(percent: manager.config.lowPowerFloor - 1,
                                                  isCharging: false, thermal: .nominal) }
        await gate.waitUntilStarted()
        let close = services.startLidActions(actions, closed: true, after: initialFloor)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(h.audio.mutes, 0)
        await gate.open()
        await initialFloor.value
        await close?.value
        XCTAssertTrue(h.guardFake.lowPower)
        XCTAssertEqual(h.audio.mutes, 1)
        XCTAssertEqual(try h.store.loadState()?.savedMuted, false)
        XCTAssertEqual(try h.store.loadState()?.frozenPids, [100])
        await manager.end(reason: .user)
        services.stop()
    }

    @MainActor
    func testInitialLidActionsDoNotOutliveSessionOrLidState() async throws {
        for outcome in ["battery", "thermal", "stopped", "replacement", "opened"] {
            let h = Harness(); defer { h.home.destroy() }
            let manager = h.makeManager()
            manager.config.muteOnLidClose = true
            manager.config.dockerRule = false
            let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
            let actions = LidActions(manager: manager, freezer: freezer,
                                     docker: DockerRule(freezer: freezer, probe: { false }), audio: h.audio)
            let services = AppServices(paths: h.home.paths, notifier: h.notifier, audio: h.audio,
                                       processControl: h.procs,
                                       locationPermission: LocationPermission(authorizationStatus: .authorizedAlways))
            await manager.start(duration: 3600)
            services.beginSession(for: manager)
            let gate = AsyncGate()
            let floors = FloorRuleDriver(manager: manager, notifier: h.notifier)
            let initialFloor = Task {
                await gate.wait()
                if outcome == "battery" {
                    await floors.run(percent: 0, isCharging: false, thermal: .nominal)
                } else if outcome == "thermal" {
                    await floors.run(percent: 100, isCharging: true, thermal: .critical)
                }
            }
            await gate.waitUntilStarted()
            let close = services.startLidActions(actions, closed: true, after: initialFloor)
            if outcome == "stopped" { services.stop() }
            if outcome == "replacement" {
                await manager.end(reason: .user)
                await manager.start(duration: 7200)
            }
            if outcome == "opened" { services.startLidActions(actions, closed: false) }
            await gate.open()
            await close?.value
            XCTAssertEqual(h.audio.mutes, 0, outcome)
            XCTAssertNil(try h.store.loadState()?.savedMuted, outcome)
            if outcome == "battery" || outcome == "thermal" { XCTAssertFalse(manager.isActive, outcome) }
            services.stop()
            await manager.end(reason: .user)
        }
    }

    @MainActor
    func testInitiallyClosedLidAppliesJournaledActionsWithoutHardwareEvents() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.muteOnLidClose = true
        manager.config.dockerRule = false
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        let actions = LidActions(manager: manager, freezer: freezer,
                                 docker: DockerRule(freezer: freezer, probe: { false }), audio: h.audio)
        let services = AppServices(paths: h.home.paths, notifier: h.notifier, audio: h.audio,
                                   processControl: h.procs,
                                   locationPermission: LocationPermission(authorizationStatus: .authorizedAlways))
        await manager.start(duration: 3600)
        services.beginSession(for: manager)
        XCTAssertNil(services.startLidActions(actions, closed: false))
        XCTAssertEqual(h.audio.mutes, 0)
        let close = services.startLidActions(actions, closed: true)
        await close?.value
        XCTAssertEqual(h.audio.mutes, 1)
        XCTAssertEqual(try h.store.loadState()?.savedMuted, false)
        XCTAssertFalse(manager.countdownTimerArmed)
        await manager.end(reason: .user)
        XCTAssertFalse(h.audio.muted)
        services.stop()
    }

    @MainActor
    func testLiveStatusSourceReadsEveryValueFromSystemStatus() {
        let home = TempHome()
        defer { home.destroy() }
        let services = AppServices(
            paths: home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .authorizedAlways)
        )
        services.status.lidClosed = true
        services.status.batteryPercent = 41
        services.status.isCharging = true
        services.status.wifiSSID = "iPhone"
        services.status.lastGap = 12
        services.status.frozenCount = 3
        services.status.dockerPaused = true
        services.status.throttledBrowsers = ["Chrome"]

        let source = LiveStatusSource(services: services)

        XCTAssertTrue(source.lidClosed)
        XCTAssertEqual(source.batteryPercent, 41)
        XCTAssertTrue(source.isCharging)
        XCTAssertEqual(source.wifiSSID, "iPhone")
        XCTAssertEqual(source.lastGap, 12)
        XCTAssertEqual(source.frozenCount, 3)
        XCTAssertTrue(source.dockerPaused)
        XCTAssertEqual(source.throttledBrowsers, ["Chrome"])
        XCTAssertEqual(source.locationPermission.authorizationStatus, .authorizedAlways)
    }

    @MainActor
    func testLiveStatusSourceMapsBrowserDisplayNameToBundleID() {
        let statuses = [
            BrowserStatus(bundleId: "com.google.Chrome", name: "Chrome", pid: 10, unthrottled: false),
            BrowserStatus(bundleId: "company.thebrowser.Browser", name: "Arc", pid: 11, unthrottled: false),
        ]

        XCTAssertEqual(LiveStatusSource.bundleID(forDisplayName: "Arc", in: statuses), "company.thebrowser.Browser")
        XCTAssertNil(LiveStatusSource.bundleID(forDisplayName: "Safari", in: statuses))
    }

    func testKeychainSecretStoreUsesFailoverServiceAndCurrentSSID() throws {
        let keychain = FakeKeychainStore()
        var ssid = "Phone"
        let store = KeychainHotspotSecretStore(keychain: keychain) { ssid }

        try store.save("secret")

        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "Phone"), "secret")
        XCTAssertEqual(try store.load(), "secret")

        ssid = "Other Phone"
        XCTAssertNil(try store.load())
    }

    func testKeychainSecretStoreMovesPasswordWhenSSIDChanges() throws {
        let keychain = FakeKeychainStore()
        var ssid = "Old Phone"
        let store = KeychainHotspotSecretStore(keychain: keychain) { ssid }
        try store.save("first")

        ssid = "New Phone"
        try store.save("replacement")

        XCTAssertNil(try keychain.get(service: KeychainStore.service, account: "Old Phone"))
        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "New Phone"), "replacement")
    }

    func testWiFiStatusNameExplainsLocationRedaction() {
        XCTAssertEqual(
            WiFiStatusName.display(ssid: nil, locationAuthorized: false),
            "on (name hidden until Location is allowed)"
        )
        XCTAssertEqual(WiFiStatusName.display(ssid: "Office", locationAuthorized: false), "Office")
        XCTAssertNil(WiFiStatusName.display(ssid: nil, locationAuthorized: true))
    }

    /// macOS has no `.authorizedWhenInUse`; a granted when-in-use request
    /// reports `.authorizedAlways`, which is the only grant we can observe.
    @MainActor
    func testGrantedLocationCountsAsAuthorized() {
        let permission = LocationPermission(authorizationStatus: .authorizedAlways)
        XCTAssertTrue(permission.isAuthorized)
        XCTAssertFalse(permission.isDenied)
        XCTAssertEqual(permission.statusDescription, "Allowed")
    }

    @MainActor
    func testUngrantedLocationStatusesAreNotAuthorized() {
        let denied = LocationPermission(authorizationStatus: .denied)
        XCTAssertFalse(denied.isAuthorized)
        XCTAssertTrue(denied.isDenied)
        XCTAssertEqual(denied.statusDescription, "Denied")

        let undetermined = LocationPermission(authorizationStatus: .notDetermined)
        XCTAssertFalse(undetermined.isAuthorized)
        XCTAssertEqual(undetermined.statusDescription, "Not requested")
    }
}
