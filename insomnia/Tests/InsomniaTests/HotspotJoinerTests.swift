import CoreWLAN
import XCTest
@testable import Insomnia

final class HotspotJoinerTests: XCTestCase {
    private struct Candidate: Equatable {
        let name: String
        let security: Set<CWSecurity>
        let signal: Int
    }

    private func selected(_ candidates: [Candidate], password: Bool = true) -> Candidate? {
        HotspotSecurityPolicy.select(from: candidates, passwordConfigured: password,
                                     security: { $0.security }, signal: { $0.signal })
    }

    func testConfiguredPasswordRefusesOpenLegacyEnterpriseAndUnknownMatches() {
        for mode: CWSecurity in [.none, .WEP, .dynamicWEP, .wpaPersonal, .wpaPersonalMixed,
                                  .wpaEnterprise, .wpa2Enterprise, .wpa3Enterprise, .unknown, .OWE] {
            XCTAssertNil(selected([Candidate(name: "same SSID", security: [mode], signal: -10)]))
        }
        XCTAssertNil(selected([Candidate(name: "mixed WPA1", security: [.wpaPersonalMixed, .wpa2Personal], signal: -10)]))
    }

    func testOpenFirstCannotDowngradeAndStrongestPersonalModeWinsOverSignal() {
        let open = Candidate(name: "open first", security: [.none], signal: -10)
        let wpa2 = Candidate(name: "WPA2", security: [.wpa2Personal], signal: -20)
        let transition = Candidate(name: "WPA3 transition", security: [.wpa3Transition, .wpa2Personal], signal: -30)
        let wpa3 = Candidate(name: "WPA3", security: [.wpa3Personal], signal: -80)
        XCTAssertEqual(selected([open, wpa2]), wpa2)
        XCTAssertEqual(selected([open, wpa2, transition]), transition)
        XCTAssertEqual(selected([open, wpa2, transition, wpa3]), wpa3)
    }

    func testSignalBreaksTiesOnlyWithinAcceptedSecurity() {
        let weak = Candidate(name: "weak", security: [.wpa2Personal], signal: -80)
        let strong = Candidate(name: "strong", security: [.wpa2Personal], signal: -30)
        XCTAssertEqual(selected([weak, strong]), strong)
    }

    func testEmptyPasswordOnlySelectsPasswordlessSecurity() {
        let secure = Candidate(name: "requires password", security: [.wpa3Personal], signal: -10)
        let open = Candidate(name: "open", security: [.none], signal: -20)
        let owe = Candidate(name: "OWE", security: [.OWE], signal: -70)
        XCTAssertNil(selected([secure], password: false))
        XCTAssertEqual(selected([secure, open, owe], password: false), owe)
    }
}
