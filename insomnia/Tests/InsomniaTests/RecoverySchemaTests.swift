import XCTest
@testable import Insomnia

@MainActor
final class RecoverySchemaTests: XCTestCase {
    func testNullPowerOwnershipCannotBeDecodedOrClearedByQuit() async throws {
        for key in ["sleepDisabledByUs", "lowPowerSetByUs", "originalSleepDisabled", "originalBatteryLowPowerMode"] {
            let h = Harness(); defer { h.home.destroy() }
            let bytes = Data("{\"\(key)\":null}".utf8)
            try bytes.write(to: h.home.paths.stateFile)
            XCTAssertThrowsError(try Store.makeDecoder().decode(RuntimeState.self, from: bytes), key)
            let manager = h.makeManager()
            let mayQuit = await manager.prepareToQuit()
            XCTAssertFalse(mayQuit, key)
            XCTAssertTrue(manager.cleanupPending, key)
            XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), bytes, key)
            XCTAssertEqual(h.backstop.clears, 0, key)
        }
    }

    func testMissingPowerKeysRemainBackwardCompatibleAndBooleansRoundTrip() throws {
        XCTAssertEqual(try Store.makeDecoder().decode(RuntimeState.self, from: Data("{}".utf8)), .clean)
        for value in [false, true] {
            var state = RuntimeState()
            state.sleepDisabledByUs = value
            state.lowPowerSetByUs = value
            state.originalSleepDisabled = value
            state.originalBatteryLowPowerMode = value
            let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: Store.makeEncoder().encode(state))
            XCTAssertEqual(decoded, state)
        }
    }
}
