import XCTest
@testable import ArkavoC2PA

/// HTTP contract for arkavo-rs `POST /c2pa/v1/sign`.
final class C2PASigningServiceTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.responseHeaders = [:]
    }

    func testPostsTheSignRequestAsSnakeCaseJSON() async throws {
        var captured: URLRequest?
        var capturedBody: Data?
        StubURLProtocol.handler = { request, body in
            captured = request
            capturedBody = body
            return (200, Self.successBody(manifest: Data([1, 2, 3])))
        }

        _ = try await makeService().signManifest(sampleRequest())

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://signer.test/c2pa/v1/sign")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(json["content_hash"] as? String, String(repeating: "ab", count: 32))
        XCTAssertEqual(json["container_format"] as? String, "mov")
        let ranges = try XCTUnwrap(json["exclusion_ranges"] as? [[String: Any]])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0]["start"] as? Int, 100)
        XCTAssertEqual(ranges[0]["end"] as? Int, 245)
        XCTAssertEqual(ranges[0]["box_type"] as? String, "uuid")
        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["title"] as? String, "Test Recording")
        XCTAssertEqual(metadata["creator"] as? String, "tester@arkavo.net")
        XCTAssertEqual(metadata["timestamp"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(metadata["software"] as? String, "ArkavoC2PATests")
        XCTAssertEqual(metadata["ai_generated"] as? Bool, false)
        XCTAssertNil(metadata["description"])
    }

    func testReturnsTheDecodedManifestBytes() async throws {
        let manifest = Data((0..<64).map { UInt8($0) })
        StubURLProtocol.handler = { _, _ in (200, Self.successBody(manifest: manifest)) }

        let result = try await makeService().signManifest(sampleRequest())

        XCTAssertEqual(result, manifest)
    }

    func testForbiddenMeansTheCreatorIsNotAuthorized() async throws {
        StubURLProtocol.handler = { _, _ in
            (403, Data(#"{"error":"Creator not authorized","status":"denied"}"#.utf8))
        }

        do {
            _ = try await makeService().signManifest(sampleRequest())
            XCTFail("expected creatorNotAuthorized")
        } catch C2PASigningService.ServiceError.creatorNotAuthorized(let message) {
            XCTAssertEqual(message, "Creator not authorized")
        }
    }

    func testServerErrorsCarryTheStatusAndMessage() async throws {
        StubURLProtocol.handler = { _, _ in
            (500, Data(#"{"error":"Signing failed: boom","status":"error"}"#.utf8))
        }

        do {
            _ = try await makeService().signManifest(sampleRequest())
            XCTFail("expected server error")
        } catch C2PASigningService.ServiceError.server(let status, let message) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(message, "Signing failed: boom")
        }
    }

    func testSendsTheIdentityTokenAsABearer() async throws {
        var authorization: String?
        StubURLProtocol.handler = { request, _ in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return (200, Self.successBody(manifest: Data([1])))
        }

        _ = try await makeService(accessToken: { "passkey-cwt" }).signManifest(sampleRequest())

        XCTAssertEqual(authorization, "Bearer passkey-cwt")
    }

    func testSendsNoAuthorizationWithoutAToken() async throws {
        var authorization: String?
        StubURLProtocol.handler = { request, _ in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return (200, Self.successBody(manifest: Data([1])))
        }

        _ = try await makeService(accessToken: { nil }).signManifest(sampleRequest())

        XCTAssertNil(authorization)
    }

    func testUnauthorizedMeansTheTokenWasMissingOrRejected() async throws {
        StubURLProtocol.handler = { _, _ in
            (401, Data(#"{"error":"authentication_failed","message":"missing bearer token"}"#.utf8))
        }

        do {
            _ = try await makeService().signManifest(sampleRequest())
            XCTFail("expected unauthenticated")
        } catch C2PASigningService.ServiceError.unauthenticated(let message) {
            XCTAssertEqual(message, "missing bearer token")
        }
    }

    func testUnprocessableReportsTheExclusionLengthTheServerRequires() async throws {
        StubURLProtocol.handler = { _, _ in
            (422, Data(#"{"error":"exclusion range length must equal the C2PA manifest box length","status":"error","required_exclusion_length":14032}"#.utf8))
        }

        do {
            _ = try await makeService().signManifest(sampleRequest())
            XCTFail("expected exclusionLengthMismatch")
        } catch C2PASigningService.ServiceError.exclusionLengthMismatch(let requiredLength) {
            XCTAssertEqual(requiredLength, 14032)
        }
    }

    func testTooManyRequestsCarriesRetryAfter() async throws {
        StubURLProtocol.responseHeaders = ["Retry-After": "30"]
        StubURLProtocol.handler = { _, _ in
            (429, Data(#"{"error":"Too many signing requests","status":"error"}"#.utf8))
        }

        do {
            _ = try await makeService().signManifest(sampleRequest())
            XCTFail("expected rateLimited")
        } catch C2PASigningService.ServiceError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 30)
        }
    }

    func testRejectsASuccessResponseWithoutAManifest() async throws {
        StubURLProtocol.handler = { _, _ in (200, Data(#"{"status":"success"}"#.utf8)) }

        do {
            _ = try await makeService().signManifest(sampleRequest())
            XCTFail("expected invalidResponse")
        } catch C2PASigningService.ServiceError.invalidResponse {
        }
    }

    // MARK: - Fixtures

    private func makeService(
        accessToken: C2PASigningService.AccessTokenProvider? = nil
    ) -> C2PASigningService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return C2PASigningService(
            serverURL: URL(string: "https://signer.test")!,
            session: URLSession(configuration: configuration),
            accessToken: accessToken
        )
    }

    private func sampleRequest() -> C2PASignRequest {
        C2PASignRequest(
            contentHash: String(repeating: "ab", count: 32),
            exclusionRanges: [C2PAExclusionRange(start: 100, end: 245, boxType: "uuid")],
            containerFormat: .mov,
            metadata: C2PASigningMetadata(
                title: "Test Recording",
                creator: "tester@arkavo.net",
                timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                aiGenerated: false,
                software: "ArkavoC2PATests"
            )
        )
    }

    private static func successBody(manifest: Data) -> Data {
        let body: [String: String] = [
            "manifest": manifest.base64EncodedString(),
            "manifest_hash": String(repeating: "0", count: 64),
            "status": "success",
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }
}

final class StubURLProtocol: URLProtocol {
    /// Receives the request and its body (URLSession moves `httpBody` into a stream).
    nonisolated(unsafe) static var handler: ((URLRequest, Data?) -> (Int, Data))?
    nonisolated(unsafe) static var responseHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, body) = handler(request, Self.readBody(of: request))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: Self.responseHeaders
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
