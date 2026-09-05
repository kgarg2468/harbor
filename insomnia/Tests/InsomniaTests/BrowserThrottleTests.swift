import XCTest
@testable import Insomnia

final class BrowserThrottleTests: XCTestCase {
    func testFlagsAreWholeArguments() {
        XCTAssertTrue(ChromiumFlags.hasBothFlags(args: ["Chrome"] + ChromiumFlags.required))
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: ["Chrome", ChromiumFlags.occluded]))
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: ["Chrome", "--note=" + ChromiumFlags.required.joined(separator: " ")]))
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: ["Chrome", ChromiumFlags.occluded + "-x", ChromiumFlags.renderer]))
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: []))
    }

    func testPreservedArgumentsKeepBoundariesAndQuotes() {
        let profile = ["--user-data-dir=/tmp/My 'Profile'", "--profile-directory", "Profile 1"]
        XCTAssertEqual(ChromiumFlags.preservedArgs(args: ["Google Chrome"] + profile + ["--no-first-run"]), profile)
    }

    func testChromiumBundleIdsFromAgentList() {
        var config = Config()
        config.agentList = ["dev.some.Chromium-Fork", "com.apple.Safari"]
        let ids = ChromiumFlags.chromiumBundleIds(config: config)
        XCTAssertTrue(ids.contains("com.google.Chrome"))
        XCTAssertTrue(ids.contains("dev.some.Chromium-Fork"))
        XCTAssertFalse(ids.contains("com.apple.Safari"))
    }

    func testRealProcessProfileArgumentsKeepSpaces() throws {
        let process = Process()
        let input = Pipe()
        let ready = Pipe()
        let profile = ["--user-data-dir=/tmp/My Browser Profile", "--profile-directory=Profile 1", "", "quotes'and\\slashes"]
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf x; read -r line", "argv-test"] + profile
        process.standardInput = input
        process.standardOutput = ready
        try process.run()
        defer { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
        XCTAssertEqual(try ready.fileHandleForReading.read(upToCount: 1), Data("x".utf8))
        let args = try ProcessArguments.read(pid: process.processIdentifier)
        XCTAssertEqual(Array(args.suffix(profile.count)), profile)
        XCTAssertEqual(ChromiumFlags.preservedArgs(args: args), Array(profile.prefix(2)))
    }

    func testMalformedKernelDataFailsClosed() {
        XCTAssertThrowsError(try ProcessArguments.decode([]))
        var count: Int32 = 2
        var data = withUnsafeBytes(of: &count) { Array($0) }
        data += Array("/bin/example".utf8) + [0, 0] + Array("example".utf8) + [0]
        XCTAssertThrowsError(try ProcessArguments.decode(data))
    }
}

@MainActor
final class BrowserLifecycleTests: XCTestCase {
    let original = BrowserStatus(bundleId: "com.google.Chrome", name: "Chrome", pid: 101, unthrottled: false)

    func testNewestScanWinsWhenOldReadCompletesLast() async {
        let gate = AsyncGate()
        let reads = Locked(0)
        let browser = BrowserThrottle(readArgs: { _ in
            reads.value += 1
            if reads.value == 1 { await gate.wait(); return ["Chrome"] }
            return ["Chrome"] + ChromiumFlags.required
        }, runningApps: { [self.original] })
        let old = Task { await browser.scan(config: Config()) }
        await gate.waitUntilStarted()
        _ = await browser.scan(config: Config())
        await gate.open()
        let oldResult = await old.value
        XCTAssertTrue(browser.statuses.first?.unthrottled == true)
        XCTAssertEqual(oldResult, browser.statuses)
    }

    func testQuitWhileReadingDoesNotReappearInScan() async {
        let gate = AsyncGate()
        let apps = Locked([original])
        let browser = BrowserThrottle(readArgs: { _ in await gate.wait(); return ["Chrome"] }, runningApps: { apps.value })
        let task = Task { await browser.scan(config: Config()) }
        await gate.waitUntilStarted()
        apps.value = []
        await gate.open()
        _ = await task.value
        XCTAssertTrue(browser.statuses.isEmpty)
    }

    func testStaleMenuDoesNotOpenQuitBrowser() async {
        let apps = Locked([original])
        var opened = false
        let browser = BrowserThrottle(readArgs: { _ in ["Chrome"] }, runningApps: { apps.value },
            terminate: { _ in XCTFail("must not terminate"); return true },
            open: { _, _ in opened = true; return true })
        _ = await browser.scan(config: Config())
        apps.value = []
        let result = await browser.relaunchUnthrottled(bundleId: original.bundleId)
        XCTAssertFalse(result)
        XCTAssertFalse(opened)
    }

    func testRefusedQuitDoesNotOpenOrReportSuccess() async {
        var opened = false
        let browser = BrowserThrottle(readArgs: { _ in ["Chrome"] }, runningApps: { [self.original] },
            terminate: { _ in false }, open: { _, _ in opened = true; return true })
        _ = await browser.scan(config: Config())
        let result = await browser.relaunchUnthrottled(bundleId: original.bundleId)
        XCTAssertFalse(result)
        XCTAssertFalse(opened)
    }

    func testRelaunchPreservesProfileAndVerifiesNewProcessFlags() async {
        let apps = Locked([original])
        let profile = ["--profile-directory=Profile 1", "--user-data-dir=/tmp/My Profile"]
        var openedArgs: [String] = []
        let browser = BrowserThrottle(readArgs: { pid in
            ["Chrome"] + profile + (pid == 102 ? ChromiumFlags.required : [])
        }, runningApps: { apps.value }, terminate: { _ in apps.value = []; return true }, open: { id, args in
            openedArgs = args
            apps.value = [BrowserStatus(bundleId: id, name: "Chrome", pid: 102, unthrottled: false)]
            return true
        })
        _ = await browser.scan(config: Config())
        let result = await browser.relaunchUnthrottled(bundleId: original.bundleId)
        XCTAssertTrue(result)
        XCTAssertEqual(openedArgs, ChromiumFlags.required + profile)
        XCTAssertTrue(browser.statuses.first?.unthrottled == true)
    }

    func testOpenSuccessWithoutEffectiveFlagsIsFailure() async {
        let apps = Locked([original])
        let browser = BrowserThrottle(readArgs: { _ in ["Chrome"] }, runningApps: { apps.value },
            terminate: { _ in apps.value = []; return true }, open: { id, _ in
                apps.value = [BrowserStatus(bundleId: id, name: "Chrome", pid: 102, unthrottled: false)]
                return true
            })
        _ = await browser.scan(config: Config())
        let result = await browser.relaunchUnthrottled(bundleId: original.bundleId)
        XCTAssertFalse(result)
        XCTAssertFalse(browser.statuses.first?.unthrottled ?? true)
    }
}

extension BrowserLifecycleTests {
    func testQuitWhileReadingRelaunchArgumentsDoesNotOpenBrowser() async {
        let gate = AsyncGate()
        let reads = Locked(0)
        let apps = Locked([original])
        var opened = false
        let browser = BrowserThrottle(readArgs: { _ in
            reads.value += 1
            if reads.value > 1 { await gate.wait() }
            return ["Chrome"]
        }, runningApps: { apps.value }, terminate: { _ in XCTFail("must not terminate"); return true },
            open: { _, _ in opened = true; return true })
        _ = await browser.scan(config: Config())
        let task = Task { await browser.relaunchUnthrottled(bundleId: original.bundleId) }
        await gate.waitUntilStarted()
        apps.value = []
        await gate.open()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertFalse(opened)
    }

    func testArgumentReadFailureDoesNotQuitBrowser() async {
        let reads = Locked(0)
        let browser = BrowserThrottle(readArgs: { _ in
            reads.value += 1
            if reads.value > 1 { throw CocoaError(.fileReadNoPermission) }
            return ["Chrome"]
        }, runningApps: { [self.original] },
            terminate: { _ in XCTFail("must not lose an unreadable profile"); return true },
            open: { _, _ in XCTFail("must not open"); return true })
        _ = await browser.scan(config: Config())
        let result = await browser.relaunchUnthrottled(bundleId: original.bundleId)
        XCTAssertFalse(result)
    }
}
