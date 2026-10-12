import XCTest
@testable import ArkavoSocial

@MainActor
final class AppleLinkAuthorizationCodeTests: XCTestCase {
    private func body(of request: URLRequest) throws -> [String: String] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    func testLinkSendsTheAuthorizationCodeWhenGiven() async throws {
        let client = makeTestClient()
        let http = ScriptedHTTP([.status(200, "{}")])
        client.httpData = http.perform
        client.credentialStore = FakeCredentialStore(token: "session-cwt")

        try await client.linkAppleIdentity(idToken: "apple-id-token", authorizationCode: "apple-code")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url?.path, "/oauth/apple/link")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Token"), "session-cwt")
        XCTAssertEqual(try body(of: request), ["id_token": "apple-id-token", "authorization_code": "apple-code"])
    }

    func testLinkOmitsTheAuthorizationCodeWhenNil() async throws {
        let client = makeTestClient()
        let http = ScriptedHTTP([.status(200, "{}")])
        client.httpData = http.perform
        client.credentialStore = FakeCredentialStore(token: "session-cwt")

        try await client.linkAppleIdentity(idToken: "apple-id-token", authorizationCode: nil)

        XCTAssertEqual(try body(of: XCTUnwrap(http.requests.first)), ["id_token": "apple-id-token"])
    }

    /// Deprecated itself so that calling the deprecated overload does not warn.
    @available(*, deprecated)
    func testTheOneArgumentLinkSendsNoAuthorizationCode() async throws {
        let client = makeTestClient()
        let http = ScriptedHTTP([.status(200, "{}")])
        client.httpData = http.perform
        client.credentialStore = FakeCredentialStore(token: "session-cwt")

        try await client.linkAppleIdentity(idToken: "apple-id-token")

        XCTAssertEqual(try body(of: XCTUnwrap(http.requests.first)), ["id_token": "apple-id-token"])
    }

    func testLinkWithoutASessionTokenSendsNothing() async {
        let client = makeTestClient()
        let http = ScriptedHTTP([])
        client.httpData = http.perform
        client.credentialStore = FakeCredentialStore(token: nil)

        do {
            try await client.linkAppleIdentity(idToken: "apple-id-token", authorizationCode: "apple-code")
            XCTFail("expected missingAuthToken")
        } catch AppleLinkError.missingAuthToken {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(http.requests.isEmpty)
    }
}
