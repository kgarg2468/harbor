import Foundation

/// Spec section 4: the fixed, reversible action list run on lid close and
/// undone on lid open. Every step is journaled to state.json *before* the
/// side effect; undo reads state.json, never memory.
///
/// Order on close: mute (save volume + mute state first), freeze list (one
/// journal write per app), Docker rule, stop the countdown redraw.
/// Order on open: the exact reverse, driven by `SessionManager.undoLidActions`.
@MainActor
final class LidActions {
    private weak var manager: SessionManager?
    private let freezer: any Freezing
    private let docker: DockerRule
    private let audio: any AudioControlling

    init(manager: SessionManager, freezer: any Freezing, docker: DockerRule, audio: any AudioControlling) {
        self.manager = manager
        self.freezer = freezer
        self.docker = docker
        self.audio = audio
    }

    func onClose() async {
        guard let manager, manager.isActive, !Task.isCancelled else {
            Log.info("lid closed: no session, nothing to do")
            return
        }
        let requestedSession = manager.session
        let config = manager.config

        if config.muteOnLidClose {
            muteSavingCurrent(manager)
        }

        let groups = freezer.plan(bundleIds: config.freezeList, config: config)
        for group in groups {
            freeze(group, docker: false, manager: manager)
        }

        let dockerGroup = await docker.idleDockerGroup(config: config)
        guard manager.isActive, manager.session == requestedSession, !Task.isCancelled else { return }
        if let dockerGroup {
            freeze(dockerGroup, docker: true, manager: manager)
        }

        manager.pauseCountdown()
    }

    func onOpen() async {
        guard let manager, manager.isActive, !Task.isCancelled else {
            Log.info("lid opened: no session, nothing to do")
            return
        }
        await manager.undoLidActions()
        guard manager.isActive, !Task.isCancelled else { return }
        manager.resumeCountdown()
    }

    // MARK: Private

    private func muteSavingCurrent(_ manager: SessionManager) {
        do {
            try manager.withLidTransaction {
                let saved = try manager.store.loadState() ?? manager.state
                // Never mute a new default while recovery for an earlier device is pending.
                if saved.hasAudioOwnership {
                    guard let snapshot = saved.audioSnapshot else { return }
                    try audio.mute(deviceUID: snapshot.deviceUID)
                    return
                }
                let current = try audio.snapshotDefault()
                guard current.isValid else { throw AudioControlError(what: "invalid output snapshot", status: -1) }
                try manager.journal { s in
                    s.savedOutputVolume = current.volume
                    s.savedMuted = current.muted
                    s.savedOutputDeviceUID = current.deviceUID
                }
                try audio.mute(deviceUID: current.deviceUID)
                Log.info("muted saved output device")
            }
        } catch {
            Log.error("mute on lid close failed: \(error.localizedDescription)")
        }
    }

    private func freeze(_ group: FreezeGroup, docker: Bool, manager: SessionManager) {
        do {
            try manager.withLidTransaction {
                let saved = try manager.store.loadState() ?? manager.state
                let already = Set(saved.frozenPids + saved.frozenProcesses.map(\.pid))
                let candidates = group.identities.filter { !already.contains($0.pid) }
                let identities = freezer.prepareSuspend(processes: candidates, expectedParents: group.expectedParents)
                guard !identities.isEmpty else { return }
                try manager.journal { s in
                    s.frozenProcesses.append(contentsOf: identities)
                    s.frozenPids.append(contentsOf: identities.map(\.pid))
                    if docker { s.dockerFrozen = true }
                }
                let stopped = Set(freezer.suspend(processes: identities, expectedParents: group.expectedParents))
                let skipped = Set(identities).subtracting(stopped)
                if !skipped.isEmpty {
                    try manager.journal { s in
                        s.frozenProcesses.removeAll { skipped.contains($0) }
                        s.frozenPids.removeAll { pid in skipped.contains { $0.pid == pid } }
                        if s.frozenPids.isEmpty && s.frozenProcesses.isEmpty { s.dockerFrozen = false }
                    }
                }
                Log.info("froze \(group.name) (\(stopped.count) process(es))")
            }
        } catch {
            Log.error("could not journal freeze of \(group.bundleId): \(error.localizedDescription); left running")
        }
    }
}
