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
        let result = await YouTubeClient.revoke(token: "t", send: answer(200))
        XCTAssertEqual(result, .revoked)
    }

    func testNoTokenSendsNothing() async {
        for token in [nil, ""] as [String?] {
            let result = await YouTubeClient.revoke(token: token) { _ in
                XCTFail("nothing should be sent")
                throw URLError(.badURL)
            }
            XCTAssertEqual(result, .nothingToRevoke)
        }
    }

    func testATokenGoogleNoLongerHonorsIsNothingToRevoke() async {
        let result = await YouTubeClient.revoke(token: "t", send: answer(400, #"{"error":"invalid_token"}"#))
        XCTAssertEqual(result, .nothingToRevoke)
    }

    func testAnyOtherAnswerOrATransportErrorIsFailed() async {
        for (status, body) in [(400, #"{"error":"invalid_request"}"#), (400, "not json"), (500, ""), (503, "")] {
            let result = await YouTubeClient.revoke(token: "t", send: answer(status, body))
            XCTAssertEqual(result, .failed, "\(status) \(body)")
        }
        let offline = await YouTubeClient.revoke(token: "t") { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(offline, .failed)
    }
}
