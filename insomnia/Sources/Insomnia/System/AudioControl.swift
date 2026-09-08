import AudioToolbox
import CoreAudio
import Foundation

struct AudioSnapshot: Sendable, Equatable {
    let deviceUID: String
    let volume: Float
    let muted: Bool
    var isValid: Bool { !deviceUID.isEmpty && volume.isFinite && (0...1).contains(volume) }
}

protocol AudioControlling: Sendable {
    func snapshotDefault() throws -> AudioSnapshot
    func restore(_ snapshot: AudioSnapshot) throws
    func mute(deviceUID: String) throws
}

struct AudioControlError: Error, LocalizedError, Sendable {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

struct NoopAudioControl: AudioControlling {
    func snapshotDefault() throws -> AudioSnapshot { AudioSnapshot(deviceUID: "noop", volume: 1, muted: false) }
    func restore(_ snapshot: AudioSnapshot) throws {}
    func mute(deviceUID: String) throws {}
}

/// Injectable device operations keep UID routing testable without touching system audio.
protocol AudioDeviceAccess: Sendable {
    func defaultOutputDevice() throws -> AudioObjectID
    func uid(of device: AudioObjectID) throws -> String
    func device(forUID uid: String) throws -> AudioObjectID
    func read(_ device: AudioObjectID) throws -> (volume: Float, muted: Bool)
    func apply(_ device: AudioObjectID, volume: Float, muted: Bool) throws
    func mute(_ device: AudioObjectID) throws
}

struct CoreAudioControl: AudioControlling {
    let devices: any AudioDeviceAccess
    init(devices: any AudioDeviceAccess = SystemAudioDevices()) { self.devices = devices }

    func snapshotDefault() throws -> AudioSnapshot {
        let device = try devices.defaultOutputDevice()
        let uid = try devices.uid(of: device)
        let current = try devices.read(device)
        guard !uid.isEmpty, try devices.uid(of: device) == uid else {
            throw AudioControlError(what: "output device changed during snapshot", status: -1)
        }
        let snapshot = AudioSnapshot(deviceUID: uid, volume: current.volume, muted: current.muted)
        guard snapshot.isValid else { throw AudioControlError(what: "invalid output snapshot", status: -1) }
        return snapshot
    }

    func restore(_ snapshot: AudioSnapshot) throws {
        let device = try resolve(snapshot.deviceUID)
        try devices.apply(device, volume: snapshot.volume, muted: snapshot.muted)
    }

    func mute(deviceUID: String) throws {
        try devices.mute(resolve(deviceUID))
    }

    private func resolve(_ uid: String) throws -> AudioObjectID {
        let device = try devices.device(forUID: uid)
        guard !uid.isEmpty, try devices.uid(of: device) == uid else {
            throw AudioControlError(what: "saved output device unavailable", status: -1)
        }
        return device
    }
}

struct SystemAudioDevices: AudioDeviceAccess {
    func read(_ device: AudioObjectID) throws -> (volume: Float, muted: Bool) {
        var volume: Float32 = 0
        try get(device, Self.volumeAddress, &volume, "read volume")
        var muted: UInt32 = 0
        try get(device, Self.muteAddress, &muted, "read mute")
        return (Float(volume), muted != 0)
    }

    func apply(_ device: AudioObjectID, volume: Float, muted: Bool) throws {
        var v = Float32(min(max(volume, 0), 1))
        try set(device, Self.volumeAddress, &v, "set volume")
        var m: UInt32 = muted ? 1 : 0
        try set(device, Self.muteAddress, &m, "set mute")
    }

    func mute(_ device: AudioObjectID) throws {
        var m: UInt32 = 1
        try set(device, Self.muteAddress, &m, "mute")
    }

    func uid(of device: AudioObjectID) throws -> String {
        let address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        try get(device, address, &uid, "read output device UID")
        return uid as String
    }

    func device(forUID uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr, size >= MemoryLayout<AudioObjectID>.size else {
            throw AudioControlError(what: "list audio devices", status: status)
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw AudioControlError(what: "list audio devices", status: status) }
        for device in ids where (try? self.uid(of: device)) == uid { return device }
        throw AudioControlError(what: "saved output device unavailable", status: -1)
    }

    // MARK: CoreAudio plumbing

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw AudioControlError(what: "default output device", status: status)
        }
        return device
    }

    private func get<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T, _ what: String) throws {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr else { throw AudioControlError(what: what, status: status) }
    }

    private func set<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T, _ what: String) throws {
        var addr = address
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &value) { ptr in
            AudioObjectSetPropertyData(device, &addr, 0, nil, size, UnsafeRawPointer(ptr))
        }
        guard status == noErr else { throw AudioControlError(what: what, status: status) }
    }
}
