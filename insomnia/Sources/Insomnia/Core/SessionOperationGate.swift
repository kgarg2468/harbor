import Foundation

/// MainActor prevents simultaneous access, but permits interleaving at await.
/// This FIFO gate keeps a whole lifecycle operation together across suspension.
/// Callers must use unlocked bodies for nested operations, and always release.
@MainActor
final class SessionOperationGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
