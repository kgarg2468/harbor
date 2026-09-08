import Darwin
import Foundation

/// A PID is reusable. Ownership includes its kernel birth time and boot UUID.
struct ProcessIdentity: Codable, Sendable, Equatable, Hashable {
    let pid: Int32
    let startTimeMicroseconds: UInt64
    let bootID: String

    var isValid: Bool { pid > 0 && startTimeMicroseconds > 0 && !bootID.isEmpty }
}

protocol ProcessSignaling: Sendable {
    /// Validate before journaling, excluding processes already stopped by someone else.
    func prepareSuspend(processes: [ProcessIdentity], expectedParents: [Int32: Int32]) -> [ProcessIdentity]
    /// Revalidate immediately before each SIGSTOP. Returns only successfully stopped identities.
    func suspend(processes: [ProcessIdentity], expectedParents: [Int32: Int32]) -> [ProcessIdentity]
    /// Returns unresolved identities only. Exited, replaced, or already-running processes are resolved.
    func resume(processes: [ProcessIdentity]) -> [ProcessIdentity]
}

struct ProcessSignalState: Sendable, Equatable {
    let identity: ProcessIdentity
    let ppid: Int32
    let stopped: Bool
}

enum ProcessLookup: Sendable {
    case found(ProcessSignalState)
    case exited
    case unavailable
}

struct SignalProcessControl: ProcessSignaling {
    typealias StateLookup = @Sendable (Int32) -> ProcessLookup
    /// Zero on success, otherwise the captured errno (never inspect errno later).
    typealias Signal = @Sendable (Int32, Int32) -> Int32
    private let stateLookup: StateLookup
    private let send: Signal

    init(stateLookup: @escaping StateLookup = SignalProcessControl.kernelState,
         send: @escaping Signal = { kill($0, $1) == 0 ? 0 : errno }) {
        self.stateLookup = stateLookup
        self.send = send
    }

    func prepareSuspend(processes: [ProcessIdentity], expectedParents: [Int32: Int32]) -> [ProcessIdentity] {
        processes.filter { canSuspend($0, expectedParents: expectedParents) }
    }

    func suspend(processes: [ProcessIdentity], expectedParents: [Int32: Int32]) -> [ProcessIdentity] {
        processes.filter { identity in
            guard canSuspend(identity, expectedParents: expectedParents) else { return false }
            return send(identity.pid, SIGSTOP) == 0
        }
    }

    private func canSuspend(_ identity: ProcessIdentity, expectedParents: [Int32: Int32]) -> Bool {
        guard identity.isValid, let expected = expectedParents[identity.pid],
              case let .found(current) = stateLookup(identity.pid) else { return false }
        return current.identity == identity && current.ppid == expected && !current.stopped
    }

    func resume(processes: [ProcessIdentity]) -> [ProcessIdentity] {
        processes.filter { identity in
            guard identity.isValid else { return true }
            switch stateLookup(identity.pid) {
            case .exited: return false
            case .unavailable: return true
            case let .found(current):
                guard current.identity == identity, current.stopped else { return false }
                let error = send(identity.pid, SIGCONT)
                return error != 0 && error != ESRCH
            }
        }
    }

    static func bootIdentity() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func kernelState(pid: Int32) -> ProcessLookup {
        guard pid > 0 else { return .unavailable }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else {
            return errno == ESRCH ? .exited : .unavailable
        }
        guard let boot = bootIdentity() else { return .unavailable }
        return .found(ProcessSignalState(
            identity: ProcessIdentity(pid: pid, startTimeMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, bootID: boot),
            ppid: Int32(bitPattern: info.pbi_ppid), stopped: info.pbi_status == UInt32(SSTOP)
        ))
    }
}
