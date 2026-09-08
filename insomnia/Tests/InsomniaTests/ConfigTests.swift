import XCTest
@testable import Insomnia

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = Config()
        XCTAssertEqual(c.presets, [1800, 3600, 7200, 14400, 28800, 43200, 86400, 259200])
        XCTAssertEqual(c.lowPowerFloor, 40)
        XCTAssertEqual(c.endFloor, 10)
        XCTAssertEqual(c.nudgeThreshold, 90)
        XCTAssertEqual(c.maxDuration, 30 * 24 * 3600)
        XCTAssertEqual(c.freezeList, ["com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "com.hnc.Discord"])
        XCTAssertTrue(c.agentList.contains("com.apple.Terminal"))
        XCTAssertTrue(c.agentList.contains("com.t3tools.t3code"))
        XCTAssertTrue(c.agentList.contains("com.docker.docker"))
        XCTAssertFalse(c.dockerRule)
        XCTAssertFalse(c.browserThrottleEnabled)
        XCTAssertFalse(c.muteOnLidClose)
        XCTAssertTrue(c.thermalRules)
        XCTAssertEqual(c.hotspotSSID, "")
        XCTAssertEqual(c.tmuxTargets, [])
        XCTAssertFalse(c.launchAtLogin)
    }

    func testPartialJSONFillsDefaults() throws {
        let data = Data(#"{"lowPowerFloor": 25}"#.utf8)
        let c = try Store.makeDecoder().decode(Config.self, from: data)
        var expected = Config()
        expected.lowPowerFloor = 25
        XCTAssertEqual(c, expected)
    }

    func testEmptyObjectIsDefaults() throws {
        let c = try Store.makeDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(c, Config())
    }

    func testRoundTrip() throws {
        var c = Config()
        c.hotspotSSID = "iPhone"
        c.tmuxTargets = ["main:0.1"]
        c.presets = [60]
        let data = try Store.makeEncoder().encode(c)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), c)
    }
    func testInvalidPersistedFloorsUseSafeDefaultsWithoutDroppingOtherSettings() throws {
        for (low, end) in [(100, 0), (0, 10), (40, 99), (-1, 10), (40, 100)] {
            let data = Data("{\"lowPowerFloor\":\(low),\"endFloor\":\(end),\"hotspotSSID\":\"Chosen phone\"}".utf8)
            let config = try Store.makeDecoder().decode(Config.self, from: data)
            XCTAssertEqual(config.lowPowerFloor, 40)
            XCTAssertEqual(config.endFloor, 10)
            XCTAssertEqual(config.hotspotSSID, "Chosen phone")
        }
    }

    func testInvalidFloorSavePreservesLastValidConfig() throws {
        let home = TempHome()
        defer { home.destroy() }
        let store = Store(paths: home.paths)
        try store.saveConfig(Config())
        var invalid = Config()
        invalid.endFloor = 0
        XCTAssertThrowsError(try store.saveConfig(invalid))
        XCTAssertEqual(try store.loadConfig()?.endFloor, 10)
    }

    func testBoundaryFloorsRoundTripAndOptionalIntegrationsRetainExplicitOptIn() throws {
        let home = TempHome()
        defer { home.destroy() }
        let store = Store(paths: home.paths)
        for (low, end) in [(1, 1), (99, 99), (99, 1)] {
            var config = Config()
            config.lowPowerFloor = low
            config.endFloor = end
            config.browserThrottleEnabled = true
            config.dockerRule = true
            config.muteOnLidClose = true
            try store.saveConfig(config)
            XCTAssertEqual(try store.loadConfig(), config)
        }
    }

    func testMalformedFloorDoesNotDiscardOtherConfiguration() throws {
        let config = try Store.makeDecoder().decode(Config.self, from: Data(#"{"lowPowerFloor":"disabled","hotspotSSID":"User choice"}"#.utf8))
        XCTAssertEqual(config.lowPowerFloor, 40)
        XCTAssertEqual(config.endFloor, 10)
        XCTAssertNotNil(config.floorCorrectionNotice)
        XCTAssertEqual(config.hotspotSSID, "User choice")
    }

}
