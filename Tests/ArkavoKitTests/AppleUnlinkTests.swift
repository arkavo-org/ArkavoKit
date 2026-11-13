import XCTest
@testable import ArkavoSocial

/// Unlinking Apple: identity's `DELETE /oauth/apple/link`, then the Apple account
/// stored on this device, which goes only once identity confirms the unlink.
@MainActor
final class AppleUnlinkTests: XCTestCase {
    private func client(_ outcomes: [ScriptedHTTP.Outcome], token: String? = "session-cwt") -> (ArkavoClient, ScriptedHTTP) {
        let client = makeTestClient()
        let http = ScriptedHTTP(outcomes)
        client.httpData = http.perform
        client.credentialStore = FakeCredentialStore(token: token)
        return (client, http)
    }

    // MARK: identity

    func testUnlinkSendsAnAuthenticatedDeleteWithNoBody() async throws {
        let (client, http) = client([.status(204, "")])

        try await client.unlinkAppleIdentity()

        XCTAssertEqual(http.requests.count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.absoluteString, "https://identity.example.test/oauth/apple/link")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Token"), "session-cwt")
        XCTAssertNil(request.httpBody)
    }

    func testEachRefusalIsChosenByStatusAlone() async {
        let cases: [(ScriptedHTTP.Outcome, AppleUnlinkError)] = [
            (.status(401, "Invalid X-Auth-Token"), .signInRequired),
            (.answer(429, "rate_limited", headers: ["Retry-After": "17"]), .rateLimited(retryAfterSeconds: 17)),
            (.status(429, "rate_limited"), .rateLimited(retryAfterSeconds: 60)),
            (.answer(429, "rate_limited", headers: ["Retry-After": "Wed, 11 Nov 2026 07:28:00 GMT"]), .rateLimited(retryAfterSeconds: 60)),
            (.answer(429, "rate_limited", headers: ["Retry-After": "-5"]), .rateLimited(retryAfterSeconds: 60)),
            (.status(502, "apple_token_revoke_failed"), .serverFailure),
            (.status(500, "Internal error: apple_unlink_scan_failed"), .serverFailure),
            (.status(404, ""), .unavailable),
            (.status(405, ""), .unavailable),
            (.status(200, ""), .unexpectedResponse),
            (.status(400, ""), .unexpectedResponse),
            (.status(503, ""), .unexpectedResponse),
        ]
        for (outcome, expected) in cases {
            let (client, _) = client([outcome])
            do {
                try await client.unlinkAppleIdentity()
                XCTFail("\(outcome): expected \(expected)")
            } catch let error as AppleUnlinkError {
                XCTAssertEqual(error, expected, "\(outcome)")
            } catch {
                XCTFail("\(outcome): expected \(expected), got \(error)")
            }
        }
    }

    func testWithoutASessionTokenNothingIsSent() async {
        for token in [nil, ""] as [String?] {
            let (client, http) = client([], token: token)
            do {
                try await client.unlinkAppleIdentity()
                XCTFail("expected signInRequired")
            } catch let error as AppleUnlinkError {
                XCTAssertEqual(error, .signInRequired)
            } catch {
                XCTFail("expected signInRequired, got \(error)")
            }
            XCTAssertTrue(http.requests.isEmpty)
        }
    }

    func testATransportErrorIsThrownUnchanged() async {
        let (client, _) = client([.failure(URLError(.notConnectedToInternet))])
        do {
            try await client.unlinkAppleIdentity()
            XCTFail("expected the URLError")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("expected the URLError, got \(error)")
        }
    }

    // MARK: This device

    /// The stored Apple user ID goes with the link. `verifyCredentialState()` asks Apple
    /// about a stored user ID, and Apple still authorizes it after an unlink, so one left
    /// behind would show the account linked again on the next launch.
    func testAConfirmedUnlinkForgetsTheAppleAccountOnThisDevice() async throws {
        let store = MemoryAppleAccountStore(userID: "apple-user", email: "a@example.test", fullName: "A")
        let service = AppleSignInService(store: store)
        XCTAssertTrue(service.isLinked)
        let (client, http) = client([.status(204, "")])

        try await service.unlinkAppleAccount(with: client)

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertFalse(service.isLinked)
        XCTAssertFalse(service.isProcessing)
        XCTAssertNil(service.linkedEmail)
        XCTAssertNil(service.linkedName)
        XCTAssertNil(store.userID)
        XCTAssertNil(store.email)
        XCTAssertNil(store.fullName)
        XCTAssertFalse(AppleSignInService(store: store).isLinked, "linked again on the next launch")
    }

    func testARefusedUnlinkChangesNothingOnThisDevice() async {
        let outcomes: [ScriptedHTTP.Outcome] = [
            .status(502, "apple_token_revoke_failed"),
            .status(401, "Invalid X-Auth-Token"),
            .status(200, ""),
            .failure(URLError(.timedOut)),
        ]
        for outcome in outcomes {
            let store = MemoryAppleAccountStore(userID: "apple-user")
            let service = AppleSignInService(store: store)
            let (client, _) = client([outcome])

            do {
                try await service.unlinkAppleAccount(with: client)
                XCTFail("\(outcome): expected a throw")
            } catch {}

            XCTAssertTrue(service.isLinked, "\(outcome)")
            XCTAssertFalse(service.isProcessing, "\(outcome)")
            XCTAssertEqual(store.userID, "apple-user", "\(outcome)")
        }
    }

    func testTheDeviceOnlyUnlinkSendsNothing() {
        let store = MemoryAppleAccountStore(userID: "apple-user")
        let service = AppleSignInService(store: store)

        service.unlinkAppleAccount()

        XCTAssertFalse(service.isLinked)
        XCTAssertNil(store.userID)
    }
}

/// The device's Apple account items in memory.
@MainActor
final class MemoryAppleAccountStore: AppleAccountStore {
    var userID: String?
    var email: String?
    var fullName: String?

    init(userID: String? = nil, email: String? = nil, fullName: String? = nil) {
        self.userID = userID
        self.email = email
        self.fullName = fullName
    }

    func appleUserID() -> String? { userID }
    func appleEmail() -> String? { email }
    func appleFullName() -> String? { fullName }
    func saveAppleUserID(_ userID: String) throws { self.userID = userID }
    func saveAppleEmail(_ email: String) throws { self.email = email }
    func saveAppleFullName(_ fullName: String) throws { self.fullName = fullName }

    func deleteAppleAccount() {
        userID = nil
        email = nil
        fullName = nil
    }
}
