import Foundation

/// Everything Insomnia has changed on the machine and must undo.
/// Written to disk *before* each change is made and undone from disk, never
/// from memory (spec section 8 invariants).
struct RuntimeState: Codable, Equatable, Sendable {
    var sleepDisabledByUs: Bool = false
    var lowPowerSetByUs: Bool = false
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
        sleepDisabledByUs || lowPowerSetByUs || hasUnresolvedOwnedChanges
    }

    // Tolerate missing keys so a state.json written by an older build, or by
    // backstop.sh, still decodes.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sleepDisabledByUs = try c.decodeIfPresent(Bool.self, forKey: .sleepDisabledByUs) ?? false
        lowPowerSetByUs = try c.decodeIfPresent(Bool.self, forKey: .lowPowerSetByUs) ?? false
        frozenPids = try c.decodeIfPresent([Int32].self, forKey: .frozenPids) ?? []
        frozenProcesses = try c.decodeIfPresent([ProcessIdentity].self, forKey: .frozenProcesses) ?? []
        dockerFrozen = try c.decodeIfPresent(Bool.self, forKey: .dockerFrozen) ?? false
        savedOutputVolume = try c.decodeIfPresent(Float.self, forKey: .savedOutputVolume)
        savedMuted = try c.decodeIfPresent(Bool.self, forKey: .savedMuted)
        savedOutputDeviceUID = try c.decodeIfPresent(String.self, forKey: .savedOutputDeviceUID)
    }
}
