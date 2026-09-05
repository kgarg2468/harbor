import Security
import XCTest
@testable import Insomnia

@MainActor
final class MaintenanceTests: XCTestCase {
    func testPurgeIsExplicitAndRunsAfterLoginUnregistration() {
        for purge in [false, true] {
            var calls: [String] = []
            let args = ["--maintenance-uninstall"] + (purge ? ["--purge"] : [])
            XCTAssertEqual(MaintenanceCommand.run(arguments: args, isAppBundle: true,
                unregister: { calls.append("unregister") }, purgeHotspots: { calls.append("purge") }), 0)
            XCTAssertEqual(calls, purge ? ["unregister", "purge"] : ["unregister"])
        }
    }

    func testWrongBundleUnknownArgumentsAndUnregistrationFailureNeverPurge() {
        for args in [["--maintenance-uninstall"], ["--maintenance-uninstall", "--unknown"]] {
            XCTAssertNotEqual(MaintenanceCommand.run(arguments: args, isAppBundle: false,
                unregister: { XCTFail() }, purgeHotspots: { XCTFail() }), 0)
        }
        XCTAssertEqual(MaintenanceCommand.run(arguments: ["--maintenance-uninstall", "--purge"], isAppBundle: true,
            unregister: { throw CocoaError(.fileWriteUnknown) }, purgeHotspots: { XCTFail() }), 1)
    }

    func testKeychainPurgeDeletesOnlyServiceAndNeverRequestsValues() throws {
        for result in [errSecSuccess, errSecItemNotFound] {
            try KeychainStore().deleteService(service: KeychainStore.service) { query in
                let values = query as NSDictionary
                XCTAssertEqual(values.count, 2)
                XCTAssertEqual(values[kSecClass] as? String, kSecClassGenericPassword as String)
                XCTAssertEqual(values[kSecAttrService] as? String, "insomnia-hotspot")
                XCTAssertNil(values[kSecValueData])
                XCTAssertNil(values[kSecReturnData])
                return result
            }
        }
        XCTAssertThrowsError(try KeychainStore().deleteService(service: KeychainStore.service) { _ in errSecAuthFailed })
    }

    func testPowerSchemaValidationRejectsUnknownWithoutChangingJournal() throws {
        let home = TempHome()
        defer { home.destroy() }
        let file = home.root.appendingPathComponent("stage.json")
        for json in [#"{"originalSleepDisabled":1}"#, #"{"originalBatteryLowPowerMode":null}"#, #"{"sleepDisabledByUs":"true"}"#] {
            let bytes = Data(json.utf8)
            try bytes.write(to: file)
            XCTAssertFalse(RecoveryCommand.validate(stateFile: file))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
        try Data(#"{"originalSleepDisabled":true,"originalBatteryLowPowerMode":false}"#.utf8).write(to: file)
        XCTAssertTrue(RecoveryCommand.validate(stateFile: file))
    }
}
