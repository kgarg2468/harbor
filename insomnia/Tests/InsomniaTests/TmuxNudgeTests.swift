import XCTest
@testable import Insomnia

final class TmuxNudgeTests: XCTestCase {
    func testPaneNamesAndErrorMetadataNeverReachPersistentLog() async throws {
        let home = TempHome(); defer { home.destroy() }
        let nudge = TmuxNudge { target in
            if target == "PRIVATE_SUCCESS" { return true }
            if target == "PRIVATE_REJECTED" { return false }
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "/Users/PRIVATE_USER/PRIVATE_PROJECT"])
        }
        let count = await nudge.nudge(targets: ["PRIVATE_SUCCESS", "PRIVATE_REJECTED", "PRIVATE_FAILED"])
        XCTAssertEqual(count, 1)
        let text = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE"))
        XCTAssertTrue(text.contains("tmux.nudge-sent"))
        XCTAssertTrue(text.contains("tmux.nudge-rejected"))
        XCTAssertTrue(text.contains("tmux.nudge-failed"))
    }
}
