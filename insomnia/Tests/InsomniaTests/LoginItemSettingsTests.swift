import XCTest
@testable import Insomnia

@MainActor
final class LoginItemSettingsTests: XCTestCase {
    func testFailedConfigWriteStillReportsObservedLoginState() throws {
        for previous in [false, true] {
            let h = Harness(); defer { h.home.destroy() }
            let manager = h.makeManager()
            manager.config.launchAtLogin = previous
            let editor = SettingsEditor(manager: manager)
            try FileManager.default.removeItem(at: h.home.paths.configFile)
            try FileManager.default.createDirectory(at: h.home.paths.configFile, withIntermediateDirectories: false)
            var observed = previous
            let displayed = editor.setLaunchAtLogin(!previous, apply: { observed = $0 }, isEnabled: { observed })
            XCTAssertEqual(displayed, !previous)
            XCTAssertEqual(observed, !previous)
            XCTAssertEqual(manager.config.launchAtLogin, previous)
            XCTAssertTrue(editor.error?.contains("not saved") ?? false)
        }
    }

    func testRegistrationFailureIsReportedWithoutPersistingRequestedValue() throws {
        let h = Harness(); defer { h.home.destroy() }
        let manager = h.makeManager()
        let before = try Data(contentsOf: h.home.paths.configFile)
        let editor = SettingsEditor(manager: manager)
        let displayed = editor.setLaunchAtLogin(true, apply: { _ in throw CocoaError(.fileWriteNoPermission) }, isEnabled: { false })
        XCTAssertFalse(displayed)
        XCTAssertFalse(manager.config.launchAtLogin)
        XCTAssertEqual(try Data(contentsOf: h.home.paths.configFile), before)
        XCTAssertTrue(editor.error?.contains("Login item:") ?? false)
    }

    func testSuccessfulRequestPersistsObservedRatherThanAssumedState() throws {
        let h = Harness(); defer { h.home.destroy() }
        let manager = h.makeManager()
        let editor = SettingsEditor(manager: manager)
        // A request can succeed while macOS still requires user approval.
        let displayed = editor.setLaunchAtLogin(true, apply: { _ in }, isEnabled: { false })
        XCTAssertFalse(displayed)
        XCTAssertFalse(manager.config.launchAtLogin)
        XCTAssertEqual(try h.store.loadConfig()?.launchAtLogin, false)
    }
}
