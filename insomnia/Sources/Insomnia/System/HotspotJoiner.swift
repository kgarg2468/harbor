import CoreWLAN
import Foundation

protocol HotspotJoining: Sendable {
    /// Returns false when the SSID-filtered scan finds no matching network.
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool
}

enum HotspotJoinError: Error, LocalizedError {
    case missingInterface(String)

    var errorDescription: String? {
        switch self {
        case let .missingInterface(name):
            return "CoreWLAN could not open Wi-Fi interface \(name)"
        }
    }
}

/// CoreWLAN does not expose a requested authentication mode on association.
/// Reject legacy/mixed WPA1 matches before selecting a password-bearing network.
/// Prefer WPA3 Personal, then WPA3/WPA2 transition, then WPA2 Personal.
enum HotspotSecurityPolicy {
    static let modes: [CWSecurity] = [.none, .WEP, .dynamicWEP, .wpaPersonal, .wpaPersonalMixed,
                                      .wpa2Personal, .wpa3Personal, .wpa3Transition,
                                      .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise,
                                      .wpa3Enterprise, .OWE, .oweTransition, .unknown]

    static func select<Candidate>(from candidates: [Candidate], passwordConfigured: Bool,
                                  security: (Candidate) -> Set<CWSecurity>, signal: (Candidate) -> Int) -> Candidate? {
        let ranked = candidates.compactMap { candidate -> (Candidate, Int, Int)? in
            let modes = security(candidate)
            let rank: Int
            if passwordConfigured {
                let refused: Set<CWSecurity> = [.none, .WEP, .dynamicWEP, .wpaPersonal, .wpaPersonalMixed,
                                                .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise,
                                                .wpa3Enterprise, .OWE, .oweTransition, .unknown]
                guard modes.isDisjoint(with: refused) else { return nil }
                if modes.contains(.wpa3Personal) { rank = 3 }
                else if modes.contains(.wpa3Transition) { rank = 2 }
                else if modes.contains(.wpa2Personal) { rank = 1 }
                else { return nil }
            } else {
                if modes.contains(.OWE) { rank = 3 }
                else if modes.contains(.oweTransition) { rank = 2 }
                else if modes == [.none] { rank = 1 }
                else { return nil }
            }
            return (candidate, rank, signal(candidate))
        }
        return ranked.max { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }
}

struct CoreWLANHotspotJoiner: HotspotJoining {
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName) else {
            throw HotspotJoinError.missingInterface(interfaceName)
        }
        // macOS may require Location Services permission for SSID visibility.
        // Keep this scan SSID-filtered: association works with the returned
        // CWNetwork even when its `ssid` property is redacted.
        let networks = try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
        guard let network = HotspotSecurityPolicy.select(from: Array(networks), passwordConfigured: !password.isEmpty,
            security: { network in Set(HotspotSecurityPolicy.modes.filter { network.supportsSecurity($0) }) },
            signal: { $0.rssiValue }) else { return false }
        try interface.associate(to: network, password: password.isEmpty ? nil : password)
        return true
    }
}
