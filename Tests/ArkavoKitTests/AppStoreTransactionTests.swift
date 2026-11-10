import XCTest
@testable import ArkavoSocial

/// The App Store transaction submit (ArkavoKit #78; authnz-rs `docs/online-play-entitlement.md` and
/// `src/app_store.rs` at 04a995d) and the account IDs an app sets StoreKit's appAccountToken from (#77).
@MainActor
final class AppStoreTransactionTests: XCTestCase {
    private static let account = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
    private static let token = TestCWT.token(sub: account.uuidString.lowercased())
    private static let jws = "eyJhbGciOiJFUzI1NiJ9.e30.c2ln"
    private static let answer =
        #"{"active":true,"expires_at":1796947200,"environment":"Sandbox","entitlement":"https://arkavo.net/attr/network/value/online-play","token_can_publish":false}"#

    private func client(token: String? = AppStoreTransactionTests.token, _ outcomes: [ScriptedHTTP.Outcome]) -> (ArkavoClient, ScriptedHTTP) {
        let client = makeTestClient()
        client.credentialStore = FakeCredentialStore(token: token, handle: "alice")
        let http = ScriptedHTTP(outcomes)
        client.httpData = http.perform
        return (client, http)
    }

    private func assertSubmit(
        throws expected: AppStoreTransactionError,
        _ client: ArkavoClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.submitAppStoreTransaction(Self.jws)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as AppStoreTransactionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Submit

    func testSubmitPostsTheTransactionWithTheStoredTokenAndReturnsIdentitysAnswer() async throws {
        let (client, http) = client([.status(200, Self.answer)])

        let status = try await client.submitAppStoreTransaction(Self.jws)

        XCTAssertEqual(status, AppStoreTransactionStatus(
            active: true,
            expiresAt: Date(timeIntervalSince1970: 1_796_947_200),
            environment: "Sandbox",
            entitlement: "https://arkavo.net/attr/network/value/online-play",
            tokenCanPublish: false
        ))
        XCTAssertEqual(http.requests.count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://identity.example.test/app-store/transactions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Token"), Self.token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["signed_transaction": Self.jws])
    }

    /// An identity before 0.32.0 names no entitlement.
    func testAnAnswerWithoutAnEntitlementStillDecodes() async throws {
        let (client, _) = client([.status(200, #"{"active":false,"expires_at":1,"environment":"Production","token_can_publish":true}"#)])

        let status = try await client.submitAppStoreTransaction(Self.jws)

        XCTAssertNil(status.entitlement)
        XCTAssertFalse(status.active)
        XCTAssertTrue(status.tokenCanPublish)
        XCTAssertEqual(status.environment, "Production")
    }

    func testWithoutAStoredTokenNothingIsSent() async {
        for missing in [nil, ""] as [String?] {
            let (client, http) = client(token: missing, [.status(200, Self.answer)])

            await assertSubmit(throws: .unauthorized, client)

            XCTAssertTrue(http.requests.isEmpty)
        }
    }

    func testAnEmptyTransactionIsNotSent() async {
        let (client, http) = client([.status(200, Self.answer)])
        do {
            _ = try await client.submitAppStoreTransaction("")
            XCTFail("expected invalidTransaction")
        } catch {
            XCTAssertEqual(error as? AppStoreTransactionError, .invalidTransaction)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    /// One error for each refusal identity documents. Its bodies are plain text, not JSON.
    func testEachRefusalIsItsOwnError() async {
        let cases: [(ScriptedHTTP.Outcome, AppStoreTransactionError)] = [
            (.status(401, ""), .unauthorized),
            (.status(403, "transaction belongs to another account"), .anotherAccount),
            (.status(409, "subscription belongs to another account"), .subscriptionElsewhere),
            (.status(422, "invalid transaction"), .invalidTransaction),
            (.status(503, "app store purchases unavailable"), .unavailable),
            (.status(500, ""), .serverFailure),
            (.status(418, ""), .unexpectedResponse(status: 418)),
            (.status(200, "not json"), .unexpectedResponse(status: 200)),
        ]
        for (outcome, expected) in cases {
            let (client, http) = client([outcome])

            await assertSubmit(throws: expected, client)

            XCTAssertEqual(http.requests.count, 1, "\(expected): sent once, never retried")
        }
    }

    func testARequestWithoutAnAnswerIsTheTransportsError() async {
        let (client, _) = client([.failure(URLError(.timedOut))])
        do {
            _ = try await client.submitAppStoreTransaction(Self.jws)
            XCTFail("expected the URLError")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    /// The submit never touches the passkey session: no renewal, and the session stays.
    func testSubmitLeavesTheSessionAlone() async {
        let (client, http) = client([.status(401, "")])
        let store = InMemorySessionStore()
        store.record = PasskeySessionRecord(sessionId: "s", credential: "1.c", deviceKey: Data([1]), account: Self.account.uuidString.lowercased())
        client.passkeySessions = PasskeySessions(store: store, keys: SoftwareSessionKeys())
        let before = store.record

        await assertSubmit(throws: .unauthorized, client)

        XCTAssertEqual(http.requests.map(\.url?.path), ["/app-store/transactions"])
        XCTAssertEqual(store.record, before)
    }

    // MARK: - Account IDs

    func testTheSessionAccountIsTheAccountOfThisAppsSession() async {
        let client = makeTestClient()
        let store = InMemorySessionStore()
        client.passkeySessions = PasskeySessions(store: store, keys: SoftwareSessionKeys())

        let none = await client.sessionAccount()
        XCTAssertNil(none, "no session")

        store.record = PasskeySessionRecord(sessionId: "s", credential: "1.c", deviceKey: Data([1]), account: Self.account.uuidString.lowercased())
        let held = await client.sessionAccount()
        XCTAssertEqual(held, Self.account)

        store.record?.account = "not-a-uuid"
        let unreadable = await client.sessionAccount()
        XCTAssertNil(unreadable)
    }

    func testTheAccountOfAnAuthTokenIsItsSubject() {
        XCTAssertEqual(ArkavoClient.account(ofAuthToken: Self.token), Self.account)
        XCTAssertEqual(ArkavoClient.account(ofAuthToken: TestCWT.token(sub: Self.account.uuidString.uppercased())), Self.account)
        for unreadable in ["opaque", "", TestCWT.tokenWithoutSub(), TestCWT.token(sub: "user-1")] {
            XCTAssertNil(ArkavoClient.account(ofAuthToken: unreadable))
        }
    }
}
