import XCTest
@testable import ArkavoSocial

/// Patreon JSON:API member payloads can have `attributes.patron_status: null`
/// (never pledged / pending). That must not fail the whole members list.
final class PatreonMemberDecodeTests: XCTestCase {
    func testNullPatronStatusDecodesAsMember() throws {
        let json = """
        {
          "data": [{
            "id": "m1",
            "type": "member",
            "attributes": {
              "currently_entitled_amount_cents": 0,
              "email": null,
              "full_name": "Ada",
              "last_charge_date": null,
              "lifetime_support_cents": 0,
              "patron_status": null
            },
            "relationships": {
              "currently_entitled_tiers": { "data": [] },
              "user": {
                "data": { "id": "u1", "type": "user" },
                "links": { "related": "https://www.patreon.com/user?u=1" }
              }
            }
          }],
          "included": [],
          "meta": {
            "pagination": {
              "cursors": { "next": null },
              "total": 1
            }
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(PatreonClient.MemberResponse.self, from: json)
        XCTAssertEqual(response.data.count, 1)
        XCTAssertEqual(response.data[0].attributes.fullName, "Ada")
        XCTAssertNil(response.data[0].attributes.patronStatus)
    }

    func testActivePatronStatusStillDecodes() throws {
        let json = """
        {
          "data": [{
            "id": "m2",
            "type": "member",
            "attributes": {
              "currently_entitled_amount_cents": 800,
              "email": "ada@example.com",
              "full_name": "Ada",
              "last_charge_date": "2026-09-01T00:00:00.000+00:00",
              "lifetime_support_cents": 2400,
              "patron_status": "active_patron"
            },
            "relationships": {
              "currently_entitled_tiers": { "data": [] },
              "user": {
                "data": { "id": "u1", "type": "user" },
                "links": { "related": "https://www.patreon.com/user?u=1" }
              }
            }
          }],
          "included": [],
          "meta": {
            "pagination": {
              "cursors": { "next": null },
              "total": 1
            }
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(PatreonClient.MemberResponse.self, from: json)
        XCTAssertEqual(response.data[0].attributes.patronStatus, "active_patron")
    }
}
