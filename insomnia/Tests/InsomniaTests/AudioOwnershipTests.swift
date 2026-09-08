import CoreAudio
import XCTest
@testable import Insomnia

private final class DeviceFixture: AudioDeviceAccess, @unchecked Sendable {
    var defaultDevice: AudioObjectID = 10
    var devices: [AudioObjectID: String] = [10: "original", 20: "replacement"]
    var reads: [AudioObjectID] = []
    var writes: [AudioObjectID] = []
    var mutes: [AudioObjectID] = []
    func defaultOutputDevice() throws -> AudioObjectID { defaultDevice }
    func uid(of device: AudioObjectID) throws -> String {
        guard let uid = devices[device] else { throw AudioControlError(what: "missing", status: -1) }
        return uid
    }
    func device(forUID uid: String) throws -> AudioObjectID {
        guard let device = devices.first(where: { $0.value == uid })?.key else { throw AudioControlError(what: "missing", status: -1) }
        return device
    }
    func read(_ device: AudioObjectID) throws -> (volume: Float, muted: Bool) {
        reads.append(device)
        defaultDevice = 20 // Default changes during capture, before journaling/mute.
        return (0.4, false)
    }
    func apply(_ device: AudioObjectID, volume: Float, muted: Bool) throws { writes.append(device) }
    func mute(_ device: AudioObjectID) throws { mutes.append(device) }
}

final class AudioOwnershipTests: XCTestCase {
    func testCaptureMuteAndRestoreUseOriginalUIDDespiteDefaultChanging() throws {
        let devices = DeviceFixture()
        let audio = CoreAudioControl(devices: devices)
        let snapshot = try audio.snapshotDefault()
        try audio.mute(deviceUID: snapshot.deviceUID)
        try audio.restore(snapshot)
        XCTAssertEqual(snapshot.deviceUID, "original")
        XCTAssertEqual(devices.defaultDevice, 20)
        XCTAssertEqual(devices.reads, [10])
        XCTAssertEqual(devices.mutes, [10])
        XCTAssertEqual(devices.writes, [10])
    }

    func testMissingOriginalDeviceDoesNotTouchReplacement() throws {
        let devices = DeviceFixture()
        let audio = CoreAudioControl(devices: devices)
        let snapshot = try audio.snapshotDefault()
        devices.devices.removeValue(forKey: 10)
        XCTAssertThrowsError(try audio.restore(snapshot))
        XCTAssertTrue(devices.writes.isEmpty)
    }
}
