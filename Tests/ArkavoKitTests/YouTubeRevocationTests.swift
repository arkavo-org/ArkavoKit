import XCTest
@testable import ArkavoSocial

/// Sign-out revokes the grant at Google's OAuth revocation endpoint. These cover the
/// request and how each answer is read; the Keychain half is `signOut()` itself.
final class YouTubeRevocationTests: XCTestCase {
    private func answer(_ status: Int, _ body: String = "") -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    func testTheRevocationRequestPostsTheTokenAsAFormBody() throws {
        let request = YouTubeClient.revocationRequest(token: "1//refresh+token/with=symbols")

        XCTAssertEqual(request.httpMethod, "POST")
        // The token travels in the body, never in the URL.
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.hasPrefix("token="))
        XCTAssertFalse(body.contains("+"), "a form body must percent-encode +")
        XCTAssertFalse(body.dropFirst("token=".count).contains("="))
        XCTAssertEqual(body.removingPercentEncoding, "token=1//refresh+token/with=symbols")
    }

    func testA200IsRevoked() async {
        let result = await YouTubeClient.revoke(token: "t", isRefreshToken: true, send: answer(200))
        XCTAssertEqual(result, .revoked)
    }

    func testNoTokenSendsNothing() async {
        for token in [nil, ""] as [String?] {
            let result = await YouTubeClient.revoke(token: token, isRefreshToken: true) { _ in
                XCTFail("nothing should be sent")
                throw URLError(.badURL)
            }
            XCTAssertEqual(result, .nothingToRevoke)
        }
    }

    func testARefreshTokenGoogleNoLongerHonorsIsNothingToRevoke() async {
        let result = await YouTubeClient.revoke(
            token: "t", isRefreshToken: true, send: answer(400, #"{"error":"invalid_token"}"#))
        XCTAssertEqual(result, .nothingToRevoke)
    }

    /// An access token can be invalid only because it expired; the grant may still stand.
    func testAnInvalidAccessTokenIsFailedNotGone() async {
        let result = await YouTubeClient.revoke(
            token: "t", isRefreshToken: false, send: answer(400, #"{"error":"invalid_token"}"#))
        XCTAssertEqual(result, .failed)
        let revoked = await YouTubeClient.revoke(token: "t", isRefreshToken: false, send: answer(200))
        XCTAssertEqual(revoked, .revoked)
    }

    func testAnyOtherAnswerOrATransportErrorIsFailed() async {
        for (status, body) in [(400, #"{"error":"invalid_request"}"#), (400, "not json"), (500, ""), (503, "")] {
            let result = await YouTubeClient.revoke(token: "t", isRefreshToken: true, send: answer(status, body))
            XCTAssertEqual(result, .failed, "\(status) \(body)")
        }
        let offline = await YouTubeClient.revoke(token: "t", isRefreshToken: true) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(offline, .failed)
    }
}

/// Google reports a grant the person removed (or that expired) as `invalid_grant` on a token
/// refresh. Only that answer ends the stored session; anything else may be a passing failure.
final class YouTubeAccessWithdrawnTests: XCTestCase {
    func testOnlyInvalidGrantOnARefreshMeansTheGrantIsGone() {
        func withdrawn(_ status: Int, _ body: String) -> Bool {
            YouTubeClient.grantWithdrawn(status: status, data: Data(body.utf8))
        }
        XCTAssertTrue(withdrawn(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#))
        XCTAssertTrue(withdrawn(400, #"{"error":"invalid_grant"}"#))

        XCTAssertFalse(withdrawn(400, #"{"error":"invalid_request"}"#))
        XCTAssertFalse(withdrawn(401, #"{"error":"invalid_client"}"#))
        XCTAssertFalse(withdrawn(400, "not json"))
        XCTAssertFalse(withdrawn(500, #"{"error":"invalid_grant"}"#), "a server error is not a verdict on the grant")
        XCTAssertFalse(withdrawn(503, ""))
        XCTAssertFalse(withdrawn(200, #"{"error":"invalid_grant"}"#))
    }

    func testTheWithdrawnErrorTellsThePersonToSignInAgain() {
        XCTAssertEqual(
            YouTubeError.accessWithdrawn.errorDescription,
            "YouTube access was removed in your Google Account. Sign in again to reconnect.")
    }
}
