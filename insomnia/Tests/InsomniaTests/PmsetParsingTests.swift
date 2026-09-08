import XCTest
@testable import Insomnia

final class PmsetParsingTests: XCTestCase {
    let withFlag = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     SleepDisabled        1
     hibernatefile        /var/vm/sleepimage
     powernap             0
     lidwake              1
     disksleep            10
     sleep                1 (sleep prevented by powerd, coreaudiod)
     displaysleep         10
    """

    let withoutFlag = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             0
     lidwake              1
     disksleep            10
     sleep                1
     displaysleep         10
    """

    let zeroFlag = """
    Currently in use:
     SleepDisabled        0
     sleep                1
    """

    func testDetectsSleepDisabledOne() throws {
        XCTAssertTrue(try PmsetSleepGuard.parseSleepDisabled(withFlag))
    }

    func testAbsentFlagIsUnknown() {
        XCTAssertThrowsError(try PmsetSleepGuard.parseSleepDisabled(withoutFlag))
    }

    func testZeroFlagIsFalse() throws {
        XCTAssertFalse(try PmsetSleepGuard.parseSleepDisabled(zeroFlag))
    }

    func testEmptyOutputIsUnknown() {
        XCTAssertThrowsError(try PmsetSleepGuard.parseSleepDisabled(""))
    }

    func testDoesNotMatchSubstringsOfOtherKeys() {
        XCTAssertThrowsError(try PmsetSleepGuard.parseSleepDisabled(" SleepDisabledFoo 1\n"))
        XCTAssertThrowsError(try PmsetSleepGuard.parseSleepDisabled(" sleep 1\n"))
    }

    func testTabSeparated() throws {
        XCTAssertTrue(try PmsetSleepGuard.parseSleepDisabled("SleepDisabled\t1\n"))
    }

    func testAmbiguousSleepValuesAreUnknown() {
        for output in ["SleepDisabled 2", "SleepDisabled", "SleepDisabled 1 extra", "SleepDisabled 0\nSleepDisabled 1"] {
            XCTAssertThrowsError(try PmsetSleepGuard.parseSleepDisabled(output))
        }
    }

    func testBatteryLowPowerIgnoresACSetting() throws {
        let output = "Battery Power:\n lowpowermode 0\nAC Power:\n lowpowermode 1\n"
        XCTAssertFalse(try PmsetSleepGuard.parseBatteryLowPowerMode(output))
        XCTAssertTrue(try PmsetSleepGuard.parseBatteryLowPowerMode("AC Power:\n lowpowermode 0\nBattery Power:\n lowpowermode 1"))
    }

    func testMissingOrAmbiguousBatterySettingIsUnknown() {
        for output in ["", "AC Power:\n lowpowermode 0", "Battery Power:\n sleep 1", "Battery Power:\n lowpowermode 2", "Battery Power:\n lowpowermode 0\n lowpowermode 1", "Battery Power:\n lowpowermode 0\nBattery Power:\n lowpowermode 0"] {
            XCTAssertThrowsError(try PmsetSleepGuard.parseBatteryLowPowerMode(output))
        }
    }

    func testBatteryReadUsesCustomAndRejectsCommandFailure() async throws {
        let requests = Locked([[String]]())
        let guardService = PmsetSleepGuard { _, args in
            requests.value.append(args)
            return ShellResult(status: 1, stdout: "Battery Power:\n lowpowermode 1", stderr: "injected failure")
        }
        do { _ = try await guardService.batteryLowPowerMode(); XCTFail("failed read accepted") } catch {}
        XCTAssertEqual(requests.value, [["-g", "custom"]])
    }

    func testErrorMessageMentionsInstall() {
        let e = SleepGuardError(command: "sudo -n pmset -a disablesleep 1", status: 1, stderr: "sudo: a password is required\n")
        let msg = e.errorDescription ?? ""
        XCTAssertTrue(msg.contains("disablesleep 1"))
        XCTAssertTrue(msg.contains("password is required"))
        XCTAssertTrue(msg.contains("install.sh"))
    }
}
