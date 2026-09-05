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
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: home.paths.backstopScript)
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
