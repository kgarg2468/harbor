import XCTest
@testable import Insomnia

private struct PrivacyFailingJoiner: HotspotJoining {
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        throw NSError(domain: "fixture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PRIVATE_SSID at /Users/PRIVATE_USER/PRIVATE_PROJECT"])
    }
}

@MainActor
final class NetworkPrivacyTests: XCTestCase {
    func testMissingCredentialsAndJoinErrorsDoNotLogNetworkOrPersonalMetadata() async throws {
        let home = TempHome(); defer { home.destroy() }
        let keychain = FakeKeychainStore()
        var config = Config(); config.hotspotSSID = "PRIVATE_SSID"
        let network = NetworkFailover(paths: home.paths, keychain: keychain,
                                      hotspotJoiner: PrivacyFailingJoiner(), notifier: RecordingNotifier(),
                                      wifiInterface: "en0") { config }
        await network.joinHotspot()
        try keychain.set(service: KeychainStore.service, account: config.hotspotSSID, value: "PRIVATE_PASSWORD")
        await network.joinHotspot()
        let text = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE"))
        XCTAssertTrue(text.contains("hotspot.credentials-missing"))
        XCTAssertTrue(text.contains("hotspot.join-attempt"))
        XCTAssertTrue(text.contains("hotspot.join-failed"))
    }
}
