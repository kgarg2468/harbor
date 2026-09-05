import Darwin
import Foundation
import ServiceManagement

/// Shared by GUI cleanup and the headless helper. Callers own the journal lease.
enum OwnedRecovery {
    @discardableResult
    static func restore(_ state: inout RuntimeState, processes: any ProcessSignaling,
                        audio: any AudioControlling, persist: (RuntimeState) throws -> Void) throws -> Bool {
        var next = state
        let identifiedPIDs = Set(state.frozenProcesses.map(\.pid))
        let legacy = Set(state.frozenPids).subtracting(identifiedPIDs)
        if !state.frozenProcesses.isEmpty {
            next.frozenProcesses = processes.resume(processes: state.frozenProcesses)
            let unresolved = legacy.union(next.frozenProcesses.map(\.pid))
            next.frozenPids = state.frozenPids.filter { unresolved.contains($0) }
            for identity in next.frozenProcesses where !next.frozenPids.contains(identity.pid) {
                next.frozenPids.append(identity.pid)
            }
        }
        if next.frozenPids.isEmpty && next.frozenProcesses.isEmpty { next.dockerFrozen = false }
        if next != state { try persist(next); state = next }
        if let snapshot = state.audioSnapshot {
            do {
                try audio.restore(snapshot)
            } catch {
                FileHandle.standardError.write(Data("Saved audio device could not be restored: \(error.localizedDescription)\n".utf8))
                return false
            }
            next = state
            next.savedOutputVolume = nil
            next.savedMuted = nil
            next.savedOutputDeviceUID = nil
            try persist(next)
            state = next
        }
        return !state.hasUnresolvedOwnedChanges
    }
}

/// --recover-owned receives a staged journal from backstop.sh while its lease is
/// held. It must not acquire JournalLock or initialize AppDelegate/SwiftUI.
enum RecoveryCommand {
    static let protocolVersion = "insomnia-maintenance-v1"

    /// Pure schema validation lets shell recovery fail before any power side effect.
    static func validate(stateFile: URL) -> Bool {
        do {
            let data = try Data(contentsOf: stateFile)
            _ = try Store.makeDecoder().decode(RuntimeState.self, from: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            for key in ["sleepDisabledByUs", "lowPowerSetByUs", "originalSleepDisabled", "originalBatteryLowPowerMode"] {
                if let value = object[key] {
                    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
                }
            }
            return true
        } catch { return false }
    }

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 2, arguments[0] == "--recover-owned", arguments[1].hasPrefix("/") else {
            FileHandle.standardError.write(Data("usage: InsomniaRecovery --recover-owned /absolute/staged-state.json\n".utf8))
            return 2
        }
        return run(stateFile: URL(fileURLWithPath: arguments[1]))
    }

    static func run(stateFile: URL, processes: any ProcessSignaling = SignalProcessControl(),
                    audio: any AudioControlling = CoreAudioControl(),
                    write: (Data, URL) throws -> Void = atomicWrite) -> Int32 {
        do {
            let data = try Data(contentsOf: stateFile)
            var state = try Store.makeDecoder().decode(RuntimeState.self, from: data)
            guard var original = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 1 }
            let complete = try OwnedRecovery.restore(&state, processes: processes, audio: audio) { progress in
                let encoded = try Store.makeEncoder().encode(progress)
                let fields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                // Preserve future and power keys owned by other recovery layers.
                for key in ["frozenPids", "frozenProcesses", "dockerFrozen", "savedOutputVolume", "savedMuted", "savedOutputDeviceUID"] {
                    original[key] = fields[key]
                }
                try write(JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted, .sortedKeys]), stateFile)
            }
            if !complete {
                FileHandle.standardError.write(Data("Owned recovery incomplete; retained entries need retry or manual ownership resolution.\n".utf8))
            }
            return complete ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("Owned recovery failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".owned-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: temporary)
        guard rename(temporary.path, destination.path) == 0 else {
            throw StoreError.rename(from: temporary.path, to: destination.path, errno: errno)
        }
    }
}

/// Maintenance runs only from the actual installed app bundle, never its loose
/// recovery copy: SMAppService.mainApp derives identity from Bundle.main.
@MainActor
enum MaintenanceCommand {
    static func run(arguments: [String]) -> Int32 {
        let bundle = Bundle.main
        let isApp = bundle.bundleURL.pathExtension == "app" && bundle.bundleIdentifier == Paths.bundleIdentifier
        return run(arguments: arguments, isAppBundle: isApp, unregister: {
            if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        }, purgeHotspots: { try KeychainStore().deleteService(service: KeychainStore.service) })
    }

    static func run(arguments: [String], isAppBundle: Bool, unregister: () throws -> Void,
                    purgeHotspots: () throws -> Void) -> Int32 {
        guard arguments == ["--maintenance-uninstall"] || arguments == ["--maintenance-uninstall", "--purge"] else { return 2 }
        guard isAppBundle else {
            FileHandle.standardError.write(Data("Login cleanup requires the installed Insomnia.app executable.\n".utf8))
            return 1
        }
        do {
            try unregister()
            if arguments.last == "--purge" { try purgeHotspots() }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Maintenance incomplete: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
