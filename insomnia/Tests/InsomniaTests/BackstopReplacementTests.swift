import Foundation
import XCTest
@testable import Insomnia

private actor ReplacementRunner {
    var commands: [[String]] = []
    var rejectNextBootstrap = true
    func run(_ exe: String, _ args: [String]) async throws -> ShellResult {
        commands.append(args)
        if args.first == "bootstrap", rejectNextBootstrap {
            rejectNextBootstrap = false
            return ShellResult(status: 1, stdout: "", stderr: "injected bootstrap failure")
        }
        return ShellResult(status: 0, stdout: "", stderr: "")
    }
    func recorded() -> [[String]] { commands }
}

final class BackstopReplacementTests: XCTestCase {
    func testFailedBootstrapRestoresPreviousPlistAndReloadsPreviousJob() async throws {
        let home = TempHome()
        defer { home.destroy() }
        try RecoveryHelperFixture.install(home.paths)
        let runner = ReplacementRunner()
        let backstop = LaunchdBackstop(paths: home.paths, runner: { try await runner.run($0, $1) })
        try backstop.writePlist(endsAt: Date(timeIntervalSince1970: 1_900_000_000))
        let previous = try Data(contentsOf: home.paths.backstopPlist)
        do {
            try await backstop.schedule(endsAt: Date(timeIntervalSince1970: 1_900_003_600))
            XCTFail("injected bootstrap failure must reach caller")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: home.paths.backstopPlist), previous)
        let commands = await runner.recorded()
        XCTAssertEqual(commands.map { $0.first! }, ["bootout", "bootstrap", "bootout", "bootstrap"])
    }

    func testFailedUnloadPreservesLoadedJobUnlessAbsenceIsConfirmed() async throws {
        for status: Int32 in [0, 5, 113] {
            let home = TempHome()
            defer { home.destroy() }
            try RecoveryHelperFixture.install(home.paths)
            let commands = Locked<[[String]]>([])
            let backstop = LaunchdBackstop(paths: home.paths, runner: { _, args in
                commands.value.append(args)
                return ShellResult(status: args.first == "bootout" ? 5 : args.first == "print" ? status : 0,
                                   stdout: "", stderr: "")
            })
            try backstop.writePlist(endsAt: Date(timeIntervalSince1970: 1_900_000_000))
            let previous = try Data(contentsOf: home.paths.backstopPlist)
            do {
                try await backstop.schedule(endsAt: Date(timeIntervalSince1970: 1_900_003_600))
                XCTAssertEqual(status, 113, "only confirmed absence permits replacement")
            } catch { XCTAssertNotEqual(status, 113) }
            let recorded = commands.value
            XCTAssertEqual(recorded.map { $0.first! }, status == 113 ? ["bootout", "print", "bootstrap"] : ["bootout", "print"])
            XCTAssertEqual(recorded[1].last, "gui/\(getuid())/\(Paths.backstopLabel)")
            if status != 113 { XCTAssertEqual(try Data(contentsOf: home.paths.backstopPlist), previous) }
        }
    }

    func testMissingScriptDoesNotOverwriteExistingSchedule() async throws {
        let home = TempHome()
        defer { home.destroy() }
        let backstop = LaunchdBackstop(paths: home.paths)
        try backstop.writePlist(endsAt: Date(timeIntervalSince1970: 1_900_000_000))
        let previous = try Data(contentsOf: home.paths.backstopPlist)
        do {
            try await backstop.schedule(endsAt: Date(timeIntervalSince1970: 1_900_003_600))
            XCTFail("missing helper must fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: home.paths.backstopPlist), previous)
    }

    func testFailedRecoveryRetriesWithoutPollingSuccessfulRuns() {
        let plist = LaunchdBackstop.plistDictionary(label: "test", scriptPath: "/test", endsAt: nil)
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertEqual(plist["ThrottleInterval"] as? Int, 60)
        XCTAssertNil(plist["StartInterval"])
    }

    func testRelocatedJournalIsPassedToLaunchAgent() throws {
        let home = TempHome()
        defer { home.destroy() }
        let backstop = LaunchdBackstop(paths: home.paths)
        try backstop.writePlist(endsAt: nil)
        let data = try Data(contentsOf: home.paths.backstopPlist)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual((plist["EnvironmentVariables"] as? [String: String])?[Paths.environmentKey], home.root.path)
    }
}
