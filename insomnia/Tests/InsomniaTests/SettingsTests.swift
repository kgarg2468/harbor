import XCTest
@testable import Insomnia

@MainActor
final class SettingsTests: XCTestCase {
    func testFailedSaveLeavesLiveSettingsAndFloorsUnchangedAndExplainsFailure() throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        var floorRuns = 0
        let editor = SettingsEditor(manager: manager, reevaluateFloors: { floorRuns += 1 })
        try FileManager.default.removeItem(at: h.home.paths.configFile)
        try FileManager.default.createDirectory(at: h.home.paths.configFile, withIntermediateDirectories: false)
        var edited = manager.config
        edited.lowPowerFloor = 60

        XCTAssertFalse(editor.save(edited))
        XCTAssertEqual(manager.config.lowPowerFloor, 40)
        XCTAssertEqual(floorRuns, 0)
        XCTAssertTrue(editor.error?.contains("not saved") ?? false)
    }

    func testEditingFloorAppliesToActiveSessionWithoutNewPowerEvent() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        await manager.start(duration: 3600)
        let driver = FloorRuleDriver(manager: manager, notifier: h.notifier)
        await driver.run(percent: 50, isCharging: false, thermal: .nominal)
        XCTAssertFalse(manager.state.lowPowerSetByUs)
        var pending: Task<Void, Never>?
        let editor = SettingsEditor(manager: manager, reevaluateFloors: {
            pending = Task { await driver.run(percent: 50, isCharging: false, thermal: .nominal) }
        })
        var edited = manager.config
        edited.lowPowerFloor = 60
        XCTAssertTrue(editor.save(edited))
        XCTAssertNotNil(pending, "A settings edit must trigger reevaluation immediately")
        await pending?.value
        XCTAssertTrue(manager.state.lowPowerSetByUs)
        XCTAssertEqual(try manager.store.loadConfig()?.lowPowerFloor, 60)
        await manager.end(reason: .user)
    }

    func testUnrelatedSettingsDoNotRerunFloorsAndInvalidSettingsAreRejected() {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        var runs = 0
        let editor = SettingsEditor(manager: manager, reevaluateFloors: { runs += 1 })
        var edited = manager.config
        edited.hotspotSSID = "User choice"
        XCTAssertTrue(editor.save(edited))
        XCTAssertEqual(runs, 0)
        edited.endFloor = 70
        XCTAssertFalse(editor.save(edited))
        XCTAssertEqual(manager.config.endFloor, 10)
        XCTAssertTrue(editor.error?.contains("1–99%") ?? false)
        XCTAssertEqual(runs, 0)
    }

    func testCorrectionNoticeSurvivesLoadingUntilSuccessfulSave() throws {
        let h = Harness()
        defer { h.home.destroy() }
        try Data(#"{"lowPowerFloor":100,"endFloor":0}"#.utf8).write(to: h.home.paths.configFile)
        let manager = h.makeManager()
        XCTAssertNotNil(manager.config.floorCorrectionNotice)
        let editor = SettingsEditor(manager: manager)
        XCTAssertTrue(editor.save(manager.config))
        XCTAssertNil(manager.config.floorCorrectionNotice)
        XCTAssertNil(try manager.store.loadConfig()?.floorCorrectionNotice)
        XCTAssertFalse(try String(contentsOf: h.home.paths.configFile, encoding: .utf8).contains("floorCorrectionNotice"))
    }

    func testBrowserIntegrationDoesNothingUntilOptedIn() async {
        let home = TempHome()
        defer { home.destroy() }
        var scans = 0
        var relaunches = 0
        let browser = BrowserThrottle(readArgs: { _ in XCTFail("Should not inspect browsers"); return [] },
                                      runningApps: { scans += 1; return [] },
                                      terminate: { _ in XCTFail("Should not quit browsers"); return false },
                                      open: { _, _ in relaunches += 1; return true })
        let services = AppServices(paths: home.paths, notifier: RecordingNotifier(), audio: FakeAudioControl(),
                                   processControl: FakeProcessControl(), browser: browser)
        await services.refreshBrowsers()
        await services.relaunchUnthrottled("com.google.Chrome")
        XCTAssertEqual(scans, 0)
        XCTAssertEqual(relaunches, 0)
    }
}
