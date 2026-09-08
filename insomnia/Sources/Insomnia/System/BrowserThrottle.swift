import AppKit
import Foundation

/// Spec section 5: Chromium browsers throttle occluded windows unless
/// launched with both flags. Detect, and relaunch with them on request.
enum ChromiumFlags {
    static let occluded = "--disable-backgrounding-occluded-windows"
    static let renderer = "--disable-renderer-backgrounding"
    static let required = [occluded, renderer]

    static let knownBrowsers: [String] = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",
    ]

    /// Known Chromium ids plus any agent-list id mentioning chrome/chromium.
    static func chromiumBundleIds(config: Config) -> [String] {
        var ids = knownBrowsers
        for id in config.agentList {
            let l = id.lowercased()
            if (l.contains("chrome") || l.contains("chromium")), !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    static func hasBothFlags(args: [String]) -> Bool {
        let tokens = Set(args.dropFirst().map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0 })
        return required.allSatisfy { tokens.contains($0) }
    }

    /// Carry both Chromium profile-switch forms without splitting their values.
    static func preservedArgs(args: [String]) -> [String] {
        let switches = ["--user-data-dir", "--profile-directory"]
        var preserved: [String] = []
        var index = 1
        while index < args.count {
            let arg = args[index]
            if switches.contains(where: { arg.hasPrefix($0 + "=") }) {
                preserved.append(arg)
            } else if switches.contains(arg), index + 1 < args.count {
                preserved += [arg, args[index + 1]]
                index += 1
            }
            index += 1
        }
        return preserved
    }

}

struct BrowserStatus: Sendable, Equatable {
    let bundleId: String
    let name: String
    let pid: Int32
    let unthrottled: Bool
}

/// Waits for AppKit termination notifications with one timeout event. This
/// keeps relaunch event-driven instead of waking every few hundred ms.
@MainActor
private final class ApplicationTerminationWaiter {
    private let applications: [NSRunningApplication]
    private var pending: Set<Int32> = []
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(applications: [NSRunningApplication]) {
        self.applications = applications
    }

    func terminateAndWait(timeout: TimeInterval) async -> Bool {
        pending = Set(applications.lazy.filter { !$0.isTerminated }.map(\.processIdentifier))
        guard !pending.isEmpty else { return true }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let center = NSWorkspace.shared.notificationCenter
            observer = center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                Task { @MainActor [weak self] in self?.applicationTerminated(pid) }
            }

            let timeoutTimer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish(allTerminated: false) }
            }
            RunLoop.main.add(timeoutTimer, forMode: .common)
            timer = timeoutTimer

            for application in applications where !application.isTerminated {
                application.terminate()
            }
        }
    }

    private func applicationTerminated(_ pid: Int32) {
        pending.remove(pid)
        if pending.isEmpty { finish(allTerminated: true) }
    }

    private func finish(allTerminated: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.invalidate()
        timer = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        continuation.resume(returning: allTerminated)
    }
}

@MainActor
final class BrowserThrottle {
    typealias ArgsReader = @Sendable (_ pid: Int32) async throws -> [String]
    typealias RunningApps = @MainActor () -> [BrowserStatus]
    typealias Terminator = @MainActor ([BrowserStatus]) async -> Bool
    typealias Opener = @MainActor (String, [String]) async throws -> Bool

    private(set) var statuses: [BrowserStatus] = []
    var throttledBrowsers: [String] { statuses.filter { !$0.unthrottled }.map(\.name) }
    private let readArgs: ArgsReader
    private let runningApps: RunningApps
    private let terminate: Terminator
    private let open: Opener
    private var scanGeneration = 0
    private var relaunching: Set<String> = []

    init(readArgs: ArgsReader? = nil, runningApps: RunningApps? = nil,
         terminate: Terminator? = nil, open: Opener? = nil) {
        self.readArgs = readArgs ?? { try ProcessArguments.read(pid: $0) }
        self.runningApps = runningApps ?? {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard !app.isTerminated, let id = app.bundleIdentifier else { return nil }
                return BrowserStatus(bundleId: id, name: app.localizedName ?? id,
                                     pid: app.processIdentifier, unthrottled: false)
            }
        }
        self.terminate = terminate ?? { snapshots in
            let apps = snapshots.compactMap { NSRunningApplication(processIdentifier: $0.pid) }
            guard apps.count == snapshots.count,
                  zip(apps, snapshots).allSatisfy({ !$0.0.isTerminated && $0.0.bundleIdentifier == $0.1.bundleId }) else { return false }
            return await ApplicationTerminationWaiter(applications: apps).terminateAndWait(timeout: 10)
        }
        self.open = open ?? { id, args in
            let result = try await Shell.run("/usr/bin/open", ["-b", id, "--args"] + args, timeout: 15)
            return result.succeeded
        }
    }

    @discardableResult
    func scan(config: Config) async -> [BrowserStatus]? {
        scanGeneration += 1
        let generation = scanGeneration
        let ids = ChromiumFlags.chromiumBundleIds(config: config)
        var out: [BrowserStatus] = []
        for app in runningApps() where ids.contains(app.bundleId) {
            var unthrottled = false
            do {
                unthrottled = ChromiumFlags.hasBothFlags(args: try await readArgs(app.pid))
            } catch {
                Log.error("browser throttle: could not read args of \(app.name): \(error.localizedDescription)")
            }
            guard generation == scanGeneration, !Task.isCancelled else { return nil }
            if runningApps().contains(where: { $0.pid == app.pid && $0.bundleId == app.bundleId }) {
                out.append(BrowserStatus(bundleId: app.bundleId, name: app.name, pid: app.pid, unthrottled: unthrottled))
            }
        }
        guard generation == scanGeneration, !Task.isCancelled else { return nil }
        statuses = out
        return statuses
    }

    /// Relaunch only the still-running process shown by the most recent scan.
    /// A successful `open` is not proof that Chromium adopted the flags.
    @discardableResult
    func relaunchUnthrottled(bundleId: String) async -> Bool {
        guard !Task.isCancelled, !relaunching.contains(bundleId),
              runningApps().filter({ $0.bundleId == bundleId }).count == 1,
              let expected = statuses.first(where: { $0.bundleId == bundleId }),
              runningApps().contains(where: { $0.pid == expected.pid && $0.bundleId == bundleId }) else { return false }
        relaunching.insert(bundleId)
        defer { relaunching.remove(bundleId) }
        do {
            let args = try await readArgs(expected.pid)
            guard !Task.isCancelled,
                  runningApps().contains(where: { $0.pid == expected.pid && $0.bundleId == bundleId }) else { return false }
            let terminated = await terminate([expected])
            guard terminated, !Task.isCancelled,
                  !runningApps().contains(where: { $0.bundleId == bundleId }) else {
                Log.error("relaunch: \(bundleId) did not quit; relaunch aborted")
                return false
            }
            guard try await open(bundleId, ChromiumFlags.required + ChromiumFlags.preservedArgs(args: args)),
                  !Task.isCancelled else { return false }
            var config = Config()
            config.agentList.append(bundleId)
            guard let verifiedScan = await scan(config: config), !Task.isCancelled else { return false }
            let current = verifiedScan.filter { $0.bundleId == bundleId }
            let verified = !current.isEmpty && current.allSatisfy(\.unthrottled)
            if verified { Log.info("relaunched \(bundleId) unthrottled") }
            else { Log.error("relaunch: \(bundleId) flags could not be verified") }
            return verified
        } catch {
            Log.error("relaunch: \(bundleId) failed: \(error.localizedDescription)")
            return false
        }
    }
}
