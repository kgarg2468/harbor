import Darwin
import Foundation
import XCTest
@testable import Insomnia

final class ShellTests: XCTestCase {
    func testLeaderRemainsUnreapedWhileDescendantKeepsPipeOpen() async throws {
        let home = TempHome()
        defer { home.destroy() }
        let marker = home.root.appendingPathComponent("child-pid")
        let task = Task { try await Shell.run("/bin/sh", ["-c", "echo $$ > \"$1\"; sleep 2 & exit 0", "test", marker.path], timeout: 0.6) }
        let limit = ContinuousClock.now.advanced(by: .seconds(1))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(100))
        var info = siginfo_t()
        XCTAssertEqual(waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT), 0)
        XCTAssertEqual(info.si_pid, pid, "do not release the leader PID while later group signals remain possible")
        do { _ = try await task.value; XCTFail("inherited pipe must time out") }
        catch is ShellTimeoutError {} catch { XCTFail("unexpected error: \(error)") }
    }

    func testTimeoutRemainsBoundedWhenDescendantHoldsOutputPipes() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await Shell.run("/bin/sh", ["-c", "sleep 3 & exit 0"], timeout: 0.1)
            XCTFail("inherited output pipes must not defeat timeout")
        } catch is ShellTimeoutError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
    }

    func testCancellationStopsOwnedCommandPromptly() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let task = Task { try await Shell.run("/bin/sleep", ["3"], timeout: 10) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled command returned success") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
    }

    func testExternalSignalIsNotMisreportedAsTimeout() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "kill -TERM $$"], timeout: 5)
        XCTAssertFalse(result.succeeded)
    }

    func testDrainsBothPipesAndPreservesExitStatus() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "printf stdout; printf stderr >&2; exit 7"], timeout: 2)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.stdout, "stdout")
        XCTAssertEqual(result.stderr, "stderr")
    }

    func testMissingExecutableFailsWithoutHanging() async {
        do { _ = try await Shell.run("/nonexistent-insomnia-test", [], timeout: 1); XCTFail("launch succeeded") }
        catch is ShellError {} catch { XCTFail("unexpected error: \(error)") }
    }

    func testOutputLimitCountsBothStreamsTogether() async {
        do {
            _ = try await Shell.run("/bin/sh", ["-c", "/usr/bin/head -c 5242880 /dev/zero; /usr/bin/head -c 5242880 /dev/zero >&2"], timeout: 5)
            XCTFail("combined output must not exceed 8 MiB")
        } catch ShellError.outputLimitExceeded {} catch { XCTFail("unexpected error: \(error)") }
    }
}
