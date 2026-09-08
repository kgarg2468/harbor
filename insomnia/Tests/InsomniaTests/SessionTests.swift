import XCTest
@testable import Insomnia

final class SessionTests: XCTestCase {
    func testNewSessionsHaveDistinctDurableIdentityAndExtensionsKeepIt() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Session(startedAt: now, endsAt: now.addingTimeInterval(3600))
        let second = Session(startedAt: first.startedAt, endsAt: first.endsAt)
        XCTAssertNotNil(first.id)
        XCTAssertNotEqual(first.id, second.id)
        let bytes = try Store.makeEncoder().encode(first)
        XCTAssertEqual(try Store.makeDecoder().decode(Session.self, from: bytes), first)
        let extended = SessionMath.extended(first, by: 600, now: now, maxDuration: 7200)
        XCTAssertEqual(extended.id, first.id)
    }

    func testLegacyDecodeRetainsAbsentIdentityAcrossRepeatedLoadsAndWrites() throws {
        let bytes = Data(#"{"startedAt":"2027-01-15T08:00:00Z","endsAt":"2027-01-15T09:00:00Z","extensions":[]}"#.utf8)
        let first = try Store.makeDecoder().decode(Session.self, from: bytes)
        let second = try Store.makeDecoder().decode(Session.self, from: bytes)
        XCTAssertNil(first.id)
        XCTAssertEqual(first, second)
        let encoded = try Store.makeEncoder().encode(first)
        XCTAssertEqual(try Store.makeDecoder().decode(Session.self, from: encoded), first)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("\"id\""))
    }
}
