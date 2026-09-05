import Foundation

/// Everything Insomnia has changed on the machine and must undo.
/// Written to disk *before* each change is made and undone from disk, never
/// from memory (spec section 8 invariants).
struct RuntimeState: Codable, Equatable, Sendable {
    var sleepDisabledByUs: Bool = false
    var lowPowerSetByUs: Bool = false
    /// nil with a legacy ownership flag means restore off. New writes snapshot first.
    var originalSleepDisabled: Bool? = nil
    var originalBatteryLowPowerMode: Bool? = nil
    /// Compatibility/UI mirror. Entries without a matching identity are legacy, unresolved ownership.
    var frozenPids: [Int32] = []
    var frozenProcesses: [ProcessIdentity] = []
    var dockerFrozen: Bool = false
    /// nil when mute is off or the lid is open.
    var savedOutputVolume: Float? = nil
    var savedMuted: Bool? = nil
    var savedOutputDeviceUID: String? = nil

    var hasAudioOwnership: Bool { savedOutputDeviceUID != nil || savedOutputVolume != nil || savedMuted != nil }
    var audioSnapshot: AudioSnapshot? {
        guard let uid = savedOutputDeviceUID, !uid.isEmpty, let volume = savedOutputVolume,
              volume.isFinite, (0...1).contains(volume), let muted = savedMuted else { return nil }
        return AudioSnapshot(deviceUID: uid, volume: volume, muted: muted)
    }
    var hasUnresolvedOwnedChanges: Bool {
        !frozenPids.isEmpty || !frozenProcesses.isEmpty || dockerFrozen || hasAudioOwnership
    }

    /// A state with nothing left to undo.
    static let clean = RuntimeState()

    /// True when at least one entry still needs undoing.
    var isDirty: Bool {
        sleepDisabledByUs || lowPowerSetByUs || originalSleepDisabled != nil
            || originalBatteryLowPowerMode != nil || hasUnresolvedOwnedChanges
    }

    // Tolerate missing keys so a state.json written by an older build, or by
    // backstop.sh, still decodes.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Missing legacy keys are supported; present null is unknown ownership,
        // not evidence that no restoration is needed.
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T? {
            guard c.contains(key) else { return nil }
            return try c.decode(type, forKey: key)
        }
        sleepDisabledByUs = try value(Bool.self, .sleepDisabledByUs) ?? false
        lowPowerSetByUs = try value(Bool.self, .lowPowerSetByUs) ?? false
        originalSleepDisabled = try value(Bool.self, .originalSleepDisabled)
        originalBatteryLowPowerMode = try value(Bool.self, .originalBatteryLowPowerMode)
        frozenPids = try value([Int32].self, .frozenPids) ?? []
        frozenProcesses = try value([ProcessIdentity].self, .frozenProcesses) ?? []
        dockerFrozen = try value(Bool.self, .dockerFrozen) ?? false
        savedOutputVolume = try value(Float.self, .savedOutputVolume)
        savedMuted = try value(Bool.self, .savedMuted)
        savedOutputDeviceUID = try value(String.self, .savedOutputDeviceUID)
    }
}
