import XCTest
@testable import ArkavoSocial

/// The secretless Patreon client (Creator#121): the authorize URL and its
/// per-authorization `state`, the callback check, identity's link route, and
/// the membership the token's `arkavo_patreon` claim carries.
final class PatreonClientTests: XCTestCase {
    private static let identity = URL(string: "https://identity.example.test")!
    private static let redirect = "https://identity.arkavo.net/oauth/arkavocreator/patreon"
    private static let token = "session-token"

    /// Records requests and answers each with the next scripted outcome.
    private final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [Result<(Int, String), Error>]
        private var sent: [URLRequest] = []

        init(_ outcomes: [Result<(Int, String), Error>]) {
            self.outcomes = outcomes
        }

        var requests: [URLRequest] { lock.withLock { sent } }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let outcome: Result<(Int, String), Error> = lock.withLock {
                sent.append(request)
                return outcomes.isEmpty ? .failure(URLError(.resourceUnavailable)) : outcomes.removeFirst()
            }
            let (status, body) = try outcome.get()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private func client(_ transport: Transport, token: String? = PatreonClientTests.token) -> PatreonClient {
        PatreonClient(clientID: "creator-client", identity: Self.identity, send: transport.send, token: { token })
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func callback(_ items: [(String, String)]) -> URL {
        var components = URLComponents(string: "arkavocreator://oauth/patreon")!
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    private func assertLink(throws expected: PatreonLinkError, status: Int, body: String = "{}",
                            file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client(Transport([.success((status, body))])).link(code: "c", redirectURI: Self.redirect)
            XCTFail("expected \(expected) for \(status)", file: file, line: line)
        } catch let error as PatreonLinkError {
            XCTAssertEqual(error, expected, "\(status)", file: file, line: line)
        } catch {
            XCTFail("expected \(expected) for \(status), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Authorization

    func testAuthorizationAsksPatreonForACodeWithAFreshState() throws {
        let authorization = client(Transport([])).authorization(redirectURI: Self.redirect)

        let url = authorization.url
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.patreon.com")
        XCTAssertEqual(url.path, "/oauth2/authorize")
        XCTAssertEqual(query(url), [
            "response_type": "code",
            "client_id": "creator-client",
            "redirect_uri": Self.redirect,
            "scope": "identity identity.memberships campaigns",
            "state": authorization.state,
        ])
        XCTAssertEqual(authorization.redirectURI, Self.redirect)
        // 32 random bytes, base64url without padding.
        XCTAssertEqual(authorization.state.count, 43)
        XCTAssertTrue(authorization.state.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    func testEveryAuthorizationHasItsOwnState() {
        let client = client(Transport([]))
        XCTAssertNotEqual(client.authorization(redirectURI: Self.redirect).state,
                          client.authorization(redirectURI: Self.redirect).state)
    }

    func testTheCallbackOfThisAuthorizationGivesItsCode() throws {
        let authorization = client(Transport([])).authorization(redirectURI: Self.redirect)

        let code = try authorization.code(from: callback([("code", "the-code"), ("state", authorization.state)]))

        XCTAssertEqual(code, "the-code")
    }

    /// A forged callback must not bind someone else's Patreon account.
    func testACallbackWithoutThisAuthorizationsStateIsRefused() {
        let authorization = client(Transport([])).authorization(redirectURI: Self.redirect)
        let forged: [[(String, String)]] = [
            [("code", "c")],
            [("code", "c"), ("state", "")],
            [("code", "c"), ("state", "another")],
            [("code", "c"), ("state", authorization.state), ("state", "another")],
            [("code", "c"), ("state", authorization.state.uppercased())],
        ]
        for items in forged {
            XCTAssertThrowsError(try authorization.code(from: callback(items))) { error in
                XCTAssertEqual(error as? PatreonCallbackError, .stateMismatch, "\(items)")
            }
        }
    }

    func testADeniedAuthorizationIsReportedAsDenied() {
        let authorization = client(Transport([])).authorization(redirectURI: Self.redirect)

        XCTAssertThrowsError(try authorization.code(from: callback([("error", "access_denied"), ("state", authorization.state)]))) {
            XCTAssertEqual($0 as? PatreonCallbackError, .denied)
        }
    }

    func testACallbackWithoutOneCodeIsRefused() {
        let authorization = client(Transport([])).authorization(redirectURI: Self.redirect)
        let state = authorization.state
        for items in [[("state", state)], [("code", ""), ("state", state)], [("code", "a"), ("code", "b"), ("state", state)]] {
            XCTAssertThrowsError(try authorization.code(from: callback(items))) {
                XCTAssertEqual($0 as? PatreonCallbackError, .missingCode, "\(items)")
            }
        }
    }

    // MARK: - Link

    func testLinkSendsTheCodeAndRedirectToIdentityWithTheSessionToken() async throws {
        let transport = Transport([.success((200, #"{"patreon_user_id":"p1","role":"creator","campaign_id":"123"}"#))])

        let link = try await client(transport).link(code: "the-code", redirectURI: Self.redirect)

        XCTAssertEqual(link, PatreonLink(patreonUserID: "p1", role: .creator, campaignID: "123"))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://identity.example.test/oauth/patreon/link")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Token"), Self.token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(request.httpShouldHandleCookies)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["code": "the-code", "redirect_uri": Self.redirect], "no role: identity derives it")
    }

    func testAConsumerLinkHasNoCampaign() async throws {
        let transport = Transport([.success((200, #"{"patreon_user_id":"p2","role":"consumer"}"#))])

        let link = try await client(transport).link(code: "c", redirectURI: Self.redirect)

        XCTAssertEqual(link, PatreonLink(patreonUserID: "p2", role: .consumer, campaignID: nil))
    }

    func testWithoutASessionTokenNothingIsSent() async {
        let transport = Transport([.success((200, "{}"))])
        do {
            _ = try await client(transport, token: nil).link(code: "c", redirectURI: Self.redirect)
            XCTFail("expected signInRequired")
        } catch {
            XCTAssertEqual(error as? PatreonLinkError, .signInRequired)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testEachRefusalIsMappedByStatus() async {
        let expected: [(Int, PatreonLinkError)] = [
            (400, .misconfigured), (401, .signInRequired), (409, .linkedToAnotherAccount),
            (502, .patreonUnavailable), (503, .notConfigured), (500, .serverFailure), (418, .unexpectedResponse),
        ]
        for (status, error) in expected {
            // A body that names another error must not change the outcome.
            await assertLink(throws: error, status: status, body: #"{"error":"link_conflict"}"#)
        }
    }

    func testALinkAnswerThatIsNotALinkIsUnexpected() async {
        for body in ["{}", #"{"patreon_user_id":"p","role":"admin"}"#, #"{"role":"creator"}"#, "not json"] {
            await assertLink(throws: .unexpectedResponse, status: 200, body: body)
        }
    }

    func testATransportErrorIsRethrown() async {
        do {
            _ = try await client(Transport([.failure(URLError(.timedOut))])).link(code: "c", redirectURI: Self.redirect)
            XCTFail("expected the URLError")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    // MARK: - Membership from the token

    private func token(patreon: TestCBOR?) -> String {
        var claims: [(TestCBOR, TestCBOR)] = [(.uint(1), .text("identity.arkavo.net")), (.uint(2), .text("sub"))]
        if let patreon { claims.append((.text("arkavo_patreon"), patreon)) }
        return TestCWT.wrap(claims: TestCBOR.map(claims).encoded)
    }

    private func account(from token: String?) async throws -> PatreonAccount? {
        try await TokenPatreonAccountSource(token: { token }).account()
    }

    /// The claim as authnz-rs#128 mints it: names, creator subjects and the owned campaign's ladder.
    func testACreatorsClaimGivesRoleCampaignMembershipsAndTheLadder() async throws {
        let patreon = TestCBOR.map([
            (.text("role"), .text("creator")),
            (.text("patreon_user_id"), .text("p1")),
            (.text("campaign_id"), .text("123")),
            (.text("memberships"), .array([
                .map([(.text("campaign_id"), .text("777")), (.text("patron_status"), .text("active_patron")),
                      (.text("tier_ids"), .array([.text("9")])), (.text("tier_slugs"), .array([.text("gold")])),
                      (.text("campaign_name"), .text("Night Owls")),
                      (.text("creator_sub"), .text("0a1b2c3d-0000-4000-8000-000000000001"))]),
                .map([(.text("campaign_id"), .text("778")), (.text("tier_ids"), .array([]))]),
            ])),
            (.text("owned_campaign"), .map([
                (.text("id"), .text("123")),
                (.text("name"), .text("My Campaign")),
                (.text("tiers"), .array([
                    .map([(.text("id"), .text("10")), (.text("title"), .text("Free")),
                          (.text("amount_cents"), .uint(0)), (.text("published"), .bool(true))]),
                    .map([(.text("id"), .text("11")), (.text("title"), .text("Supporter")),
                          (.text("amount_cents"), .uint(500)), (.text("published"), .bool(false))]),
                    .map([(.text("id"), .text("12"))]),
                ])),
            ])),
            (.text("verified_at"), .uint(1_790_000_000)),
            (.text("cache_expires_at"), .uint(1_790_000_300)),
        ])

        let account = try await account(from: token(patreon: patreon))

        XCTAssertEqual(account, PatreonAccount(
            role: .creator,
            campaignID: "123",
            memberships: [
                .init(campaignID: "777", patronStatus: "active_patron", tierIDs: ["9"], tierSlugs: ["gold"],
                      campaignName: "Night Owls", creatorSubject: "0a1b2c3d-0000-4000-8000-000000000001"),
                .init(campaignID: "778", patronStatus: nil, tierIDs: [], tierSlugs: [], campaignName: nil, creatorSubject: nil),
            ],
            ownedCampaign: .init(id: "123", name: "My Campaign", tiers: [
                .init(id: "10", title: "Free", amountCents: 0, published: true),
                .init(id: "11", title: "Supporter", amountCents: 500, published: false),
                .init(id: "12", title: nil, amountCents: nil, published: nil),
            ])
        ))
        XCTAssertEqual(account?.isCreator, true)
    }

    /// An amount is read from a CBOR integer that fits an `Int`, negative included;
    /// a float, or an integer out of range, reads as no amount.
    func testATierAmountIsReadOnlyFromAnIntegerThatFits() async throws {
        let amounts: [(TestCBOR, Int?)] = [
            (.uint(500), 500),
            (.uint(0), 0),
            (.nint(99), -100),                              // CBOR -1 - 99
            (.uint(UInt64(Int.max) + 1), nil),
            (.nint(UInt64(Int.max)), Int.min),              // -1 - (2^63 - 1)
            (.nint(UInt64(Int.max) + 1), nil),
            (.raw([0xF9, 0x3C, 0x00]), nil),                // half float 1.0
            (.raw([0xFB, 0x40, 0x7F, 0x40, 0, 0, 0, 0, 0]), nil), // double 500.0
            (.text("500"), nil),
        ]
        for (encoded, expected) in amounts {
            let patreon = TestCBOR.map([
                (.text("role"), .text("creator")), (.text("patreon_user_id"), .text("p")),
                (.text("owned_campaign"), .map([
                    (.text("id"), .text("1")),
                    (.text("tiers"), .array([.map([(.text("id"), .text("t")), (.text("amount_cents"), encoded)])])),
                ])),
            ])

            let account = try await account(from: token(patreon: patreon))

            let tier = try XCTUnwrap(account?.ownedCampaign?.tiers.first, "\(encoded)")
            XCTAssertEqual(tier.amountCents, expected, "\(encoded)")
        }
    }

    /// A token minted before authnz-rs#128 has none of its fields.
    func testAClaimFromBeforeTheLadderStillReads() async throws {
        let patreon = TestCBOR.map([
            (.text("role"), .text("creator")), (.text("patreon_user_id"), .text("p1")), (.text("campaign_id"), .text("123")),
            (.text("memberships"), .array([.map([(.text("campaign_id"), .text("777")), (.text("tier_ids"), .array([.text("9")]))])])),
            (.text("verified_at"), .uint(1)), (.text("cache_expires_at"), .uint(2)),
        ])

        let account = try await account(from: token(patreon: patreon))

        XCTAssertEqual(account, PatreonAccount(
            role: .creator,
            campaignID: "123",
            memberships: [.init(campaignID: "777", patronStatus: nil, tierIDs: ["9"], tierSlugs: [], campaignName: nil, creatorSubject: nil)],
            ownedCampaign: nil
        ))
    }

    func testAConsumersClaimHasNoCampaign() async throws {
        let patreon = TestCBOR.map([
            (.text("role"), .text("consumer")), (.text("patreon_user_id"), .text("p2")),
            (.text("verified_at"), .uint(1)), (.text("cache_expires_at"), .uint(2)),
        ])

        let account = try await account(from: token(patreon: patreon))

        XCTAssertEqual(account, PatreonAccount(role: .consumer, campaignID: nil, memberships: [], ownedCampaign: nil))
        XCTAssertEqual(account?.isCreator, false)
    }

    /// identity omits the claim when Patreon is unlinked or unreachable (fail closed).
    func testNoClaimNoTokenOrAnUnknownRoleIsNoAccount() async throws {
        let unknownRole = TestCBOR.map([(.text("role"), .text("admin")), (.text("patreon_user_id"), .text("p"))])
        let duplicated = TestCWT.wrap(claims: TestCBOR.map([
            (.text("arkavo_patreon"), .map([(.text("role"), .text("consumer"))])),
            (.text("arkavo_patreon"), .map([(.text("role"), .text("creator"))])),
        ]).encoded)

        let none = try await account(from: token(patreon: nil))
        let missing = try await account(from: nil)
        let unknown = try await account(from: token(patreon: unknownRole))
        let ambiguous = try await account(from: duplicated)
        let garbage = try await account(from: "not-a-cwt")
        XCTAssertNil(none)
        XCTAssertNil(missing)
        XCTAssertNil(unknown)
        XCTAssertNil(ambiguous)
        XCTAssertNil(garbage)
    }

    /// A hostile token returns no account without trapping or recursing without bound.
    func testAHostileTokenIsNoAccountAndDoesNotCrash() async throws {
        let huge: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let hostile: [[UInt8]] = [
            [0xD8, 0x3D, 0xD2, 0x84, 0x40, 0xA0, 0x5B] + huge + [0x41, 0x00],
            [0xD8, 0x3D, 0xD2, 0x84, 0x40, 0xA0, 0x49, 0xBB] + huge + [0x41, 0x00],
            [0xD8, 0x3D, 0xD2, 0x9B] + huge,
            [0xD8, 0x3D, 0xD2, 0x84, 0x40] + [UInt8](repeating: 0x81, count: 100_000) + [0x00, 0x40, 0x40],
        ]
        for bytes in hostile {
            let account = try await account(from: TestCWT.base64URL(bytes))
            XCTAssertNil(account)
        }
    }

    // MARK: - Legacy tokens

    /// Tokens a client secret obtained must not outlive the upgrade.
    func testLegacyRemovalDeletesEveryPatreonItem() {
        var deleted: [String] = []
        PatreonClient.removeLegacyTokens { service, account in deleted.append("\(service)/\(account)") }
        XCTAssertEqual(deleted, [
            "com.arkavo.patreon/access_token",
            "com.arkavo.patreon/refresh_token",
            "com.arkavo.patreon/campaign_id",
        ])
    }
}

/// A CBOR item for building test tokens.
indirect enum TestCBOR {
    case uint(UInt64)
    case nint(UInt64)
    case bool(Bool)
    /// Bytes as they are, for items this encoder does not build (floats).
    case raw([UInt8])
    case text(String)
    case array([TestCBOR])
    case map([(TestCBOR, TestCBOR)])

    var encoded: [UInt8] {
        switch self {
        case let .uint(value): Self.head(0, value)
        case let .nint(value): Self.head(1, value)
        case let .bool(value): [value ? 0xF5 : 0xF4]
        case let .raw(bytes): bytes
        case let .text(text): Self.head(3, UInt64(text.utf8.count)) + Array(text.utf8)
        case let .array(items): Self.head(4, UInt64(items.count)) + items.flatMap(\.encoded)
        case let .map(pairs): Self.head(5, UInt64(pairs.count)) + pairs.flatMap { $0.0.encoded + $0.1.encoded }
        }
    }

    private static func head(_ major: UInt8, _ value: UInt64) -> [UInt8] {
        let type = major << 5
        switch value {
        case 0 ..< 24: return [type | UInt8(value)]
        case 24 ..< 256: return [type | 24, UInt8(value)]
        case 256 ..< 65536: return [type | 25, UInt8(value >> 8), UInt8(value & 0xFF)]
        case 65536 ..< 4_294_967_296: return [type | 26] + (0 ..< 4).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
        default: return [type | 27] + (0 ..< 8).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
        }
    }
}
