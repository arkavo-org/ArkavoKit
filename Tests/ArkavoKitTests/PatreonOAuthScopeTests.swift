import XCTest
@testable import ArkavoSocial

/// Patreon's v2 API answers 401 for /campaigns and /campaigns/{id}/members unless
/// the token carries the `campaigns` / `campaigns.members` scopes, so an
/// identity-only login can never load a creator's campaign or patrons.
final class PatreonOAuthScopeTests: XCTestCase {
    private let expected = "identity identity[email] campaigns campaigns.members campaigns.members[email]"

    private func scope(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "scope" }?.value
    }

    @MainActor
    func testAuthURLRequestsCampaignScopes() {
        let client = PatreonClient(clientId: "client", clientSecret: "secret")
        XCTAssertEqual(scope(of: client.authURL), expected)
    }

    func testOAuthURLRequestsCampaignScopes() async {
        let client = PatreonClient(clientId: "client", clientSecret: "secret")
        let url = await client.getOAuthURL()
        XCTAssertEqual(scope(of: url), expected)
    }
}
