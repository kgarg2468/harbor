import Darwin
import XCTest
@testable import Insomnia

/// Harmless real backstop peer: lockf holds the shared inode until stdin closes.
@MainActor
final class JournalLockPeer {
    let process = Process()
    private let input = Pipe()
    private let ready: URL

    init(paths: Paths, recovery: Bool = false) throws {
        ready = paths.appSupport.appendingPathComponent("peer-ready-\(UUID().uuidString)")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        let recover = recovery ? "rm -f \"$2/session.json\"; printf '{}' > \"$2/state.json\"; " : ""
        process.arguments = ["-k", "-t", "5", paths.recoveryLock.path, "/bin/sh", "-c",
                             recover + "printf ready > \"$1\"; /bin/cat > /dev/null", "peer", ready.path, paths.appSupport.path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var hasLease: Bool { FileManager.default.fileExists(atPath: ready.path) }

    func waitForLease() async throws {
        for _ in 0..<250 {
            if hasLease { return }
            if !process.isRunning { throw JournalLock.Failure.busy }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw JournalLock.Failure.busy
    }

    func release() { try? input.fileHandleForWriting.close() }
}

@MainActor
final class JournalLockTests: XCTestCase {
    func testLockfExcludesStoreAndAsyncWaitDoesNotBlockMainActor() async throws {
        let home = TempHome(); defer { home.destroy() }
        let peer = try JournalLockPeer(paths: home.paths); defer { peer.release() }
        try await peer.waitForLease()
        let store = Store(paths: home.paths)
        XCTAssertThrowsError(try store.saveState(.clean))
        let entered = Locked(false)
        let waiting = Task {
            try await JournalLock.withLease(at: home.paths.recoveryLock) {
                entered.value = true
                try store.saveState(.clean)
            }
        }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(entered.value)
        peer.release()
        try await waiting.value
        XCTAssertEqual(try store.loadState(), .clean)
    }

    func testCancellationAndTimeoutReleaseDescriptorsAndDoNotRunBody() async throws {
        let home = TempHome(); defer { home.destroy() }
        let peer = try JournalLockPeer(paths: home.paths); defer { peer.release() }
        try await peer.waitForLease()
        let waiting = Task {
            try await JournalLock.withLease(at: home.paths.recoveryLock) { XCTFail("entered locked journal") }
        }
        try await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        do { try await waiting.value; XCTFail("expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        do {
            try await JournalLock.withLease(at: home.paths.recoveryLock, timeout: .milliseconds(30)) { XCTFail("entered locked journal") }
            XCTFail("expected timeout")
        } catch JournalLock.Failure.busy {} catch { XCTFail("\(error)") }
        peer.release()
        try await JournalLock.withLease(at: home.paths.recoveryLock) { try Store(paths: home.paths).saveState(.clean) }
    }

    func testNestedStoreAccessAndThrowReleaseKeepSameInode() async throws {
        let home = TempHome(); defer { home.destroy() }
        let store = Store(paths: home.paths)
        try JournalLock.withLock(at: home.paths.recoveryLock) {
            try store.saveState(.clean)
            XCTAssertEqual(try store.loadState(), .clean)
        }
        let inode = try FileManager.default.attributesOfItem(atPath: home.paths.recoveryLock.path)[.systemFileNumber] as? NSNumber
        do {
            try await JournalLock.withLease(at: home.paths.recoveryLock) { throw JournalLock.Failure.busy }
        } catch {}
        let peer = try JournalLockPeer(paths: home.paths); defer { peer.release() }
        try await peer.waitForLease()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: home.paths.recoveryLock.path)[.systemFileNumber] as? NSNumber, inode)
    }

    func testChildCannotReuseInheritedLeaseAfterRelease() async throws {
        let home = TempHome(); defer { home.destroy() }
        let gate = AsyncGate()
        let child = try await JournalLock.withLease(at: home.paths.recoveryLock) {
            Task { @MainActor in
                await gate.wait()
                XCTAssertThrowsError(try Store(paths: home.paths).saveState(.clean))
            }
        }
        let peer = try JournalLockPeer(paths: home.paths); defer { peer.release() }
        try await peer.waitForLease()
        await gate.open()
        try await child.value
    }
}
