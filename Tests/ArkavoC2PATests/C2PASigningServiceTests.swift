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
            return (200, Self.successBody(manifest: Self.manifestStore))
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
        XCTAssertEqual(metadata["digital_source_type"] as? String, "digitalCapture")
        XCTAssertEqual(metadata["ai_generated"] as? Bool, false)
        XCTAssertNil(metadata["description"])
    }

    // MARK: - Digital source type (arkavo-rs#129)

    func testSendsTheSourceTypeWithTheAIFlagItImplies() async throws {
        for (sourceType, aiGenerated) in [
            (C2PADigitalSourceType.screenCapture, false),
            (.virtualRecording, false),
            (.trainedAlgorithmicMedia, true),
            (.compositeWithTrainedAlgorithmicMedia, true),
        ] {
            var capturedBody: Data?
            StubURLProtocol.handler = { _, body in
                capturedBody = body
                return (200, Self.successBody(manifest: Self.manifest(carrying: sourceType)))
            }

            _ = try await makeService().signManifest(sampleRequest(sourceType))

            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
            let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
            XCTAssertEqual(metadata["digital_source_type"] as? String, sourceType.rawValue)
            XCTAssertEqual(metadata["ai_generated"] as? Bool, aiGenerated, sourceType.rawValue)
        }
    }

    /// An older server ignores `digital_source_type` and signs a camera capture; the
    /// result must not pass as a screen recording
    func testRejectsAManifestWithoutTheRequestedSourceType() async throws {
        StubURLProtocol.handler = { _, _ in
            (200, Self.successBody(manifest: Self.manifest(carrying: .digitalCapture)))
        }

        do {
            _ = try await makeService().signManifest(sampleRequest(.screenCapture))
            XCTFail("expected invalidResponse")
        } catch C2PASigningService.ServiceError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("screenCapture"), message)
        }
    }

    /// `composite`'s URI is a prefix of `compositeSynthetic`'s
    func testDoesNotTakeALongerSourceTypeForTheRequestedOne() async throws {
        StubURLProtocol.handler = { _, _ in
            (200, Self.successBody(manifest: Self.manifest(carrying: .compositeSynthetic)))
        }

        do {
            _ = try await makeService().signManifest(sampleRequest(.composite))
            XCTFail("expected invalidResponse")
        } catch C2PASigningService.ServiceError.invalidResponse {
        }
    }

    /// Callers that still pass `aiGenerated` keep today's request: the flag alone, with
    /// the source type left to the server
    @available(*, deprecated)
    func testTheAIFlagAloneLeavesTheSourceTypeToTheServer() async throws {
        var capturedBody: Data?
        StubURLProtocol.handler = { _, body in
            capturedBody = body
            return (200, Self.successBody(manifest: Self.manifest(carrying: nil)))
        }
        let metadata = C2PASigningMetadata(title: "Muse", creator: "tester@arkavo.net", aiGenerated: true)
        XCTAssertNil(metadata.digitalSourceType)
        XCTAssertEqual(metadata.aiGenerated, true)

        _ = try await makeService().signManifest(C2PASignRequest(
            contentHash: String(repeating: "ab", count: 32),
            exclusionRanges: [C2PAExclusionRange(start: 100, end: 245, boxType: "uuid")],
            containerFormat: .mov,
            metadata: metadata
        ))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        let sent = try XCTUnwrap(json["metadata"] as? [String: Any])
        XCTAssertEqual(sent["ai_generated"] as? Bool, true)
        XCTAssertNil(sent["digital_source_type"])
    }

    func testTheSourceTypeSetsTheAIFlag() {
        for sourceType in C2PADigitalSourceType.allCases {
            let metadata = C2PASigningMetadata(title: "T", creator: "c", digitalSourceType: sourceType)
            let expected = sourceType == .trainedAlgorithmicMedia || sourceType == .compositeWithTrainedAlgorithmicMedia
            XCTAssertEqual(metadata.aiGenerated, expected, sourceType.rawValue)
        }
    }

    func testReturnsTheDecodedManifestBytes() async throws {
        let uri = Data("http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture".utf8)
        let manifest = box("jumb", Data((0..<64).map { UInt8($0) }) + Data([0x78, UInt8(uri.count)]) + uri)
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

    // MARK: - Device attestation (arkavo-rs#133)

    func testSendsTheDeviceTokenAsTheEntityToken() async throws {
        var entityToken: String?
        StubURLProtocol.handler = { request, _ in
            entityToken = request.value(forHTTPHeaderField: "X-Entity-Token")
            return (200, Self.successBody(manifest: Self.manifestStore))
        }

        _ = try await makeService(deviceToken: { "device-cwt" }).signManifest(sampleRequest())

        XCTAssertEqual(entityToken, "device-cwt")
    }

    func testSendsNoEntityTokenWhenThereIsNone() async throws {
        var headers: [[String: String]] = []
        StubURLProtocol.handler = { request, _ in
            headers.append(request.allHTTPHeaderFields ?? [:])
            return (200, Self.successBody(manifest: Self.manifestStore))
        }

        _ = try await makeService().signManifest(sampleRequest())
        _ = try await makeService(deviceToken: { nil }).signManifest(sampleRequest())

        XCTAssertEqual(headers.count, 2)
        XCTAssertTrue(headers.allSatisfy { $0["X-Entity-Token"] == nil }, "\(headers)")
    }

    func testForbiddenForADeviceAttestationIsItsOwnError() async throws {
        StubURLProtocol.handler = { _, _ in
            (403, Data(#"{"error":"device attestation required","required":"device_attestation"}"#.utf8))
        }

        do {
            _ = try await makeService(deviceToken: { "expired" }).signManifest(sampleRequest())
            XCTFail("expected deviceAttestationRequired")
        } catch C2PASigningService.ServiceError.deviceAttestationRequired {
        }
    }

    func testForbiddenWithARequiredEntitlementMeansAMembershipIsNeeded() async throws {
        let entitlement = "https://patreon.arkavo.com/attr/arkavo-creator/value/publish"
        StubURLProtocol.handler = { _, _ in
            (403, Data(#"{"error":"signing entitlement required","status":"error","required_entitlement":"\#(entitlement)"}"#.utf8))
        }

        do {
            _ = try await makeService().signManifest(sampleRequest())
            XCTFail("expected membershipRequired")
        } catch C2PASigningService.ServiceError.membershipRequired(let required) {
            XCTAssertEqual(required, entitlement)
        }
    }

    func testARequiredEntitlementSurvivesOtherFieldsOfTheWrongType() async throws {
        StubURLProtocol.handler = { _, _ in
            (403, Data(#"{"error":{"code":7},"required_entitlement":"publish"}"#.utf8))
        }

        do {
            _ = try await makeService().signManifest(sampleRequest())
            XCTFail("expected membershipRequired")
        } catch C2PASigningService.ServiceError.membershipRequired(let required) {
            XCTAssertEqual(required, "publish")
        }
    }

    func testANonStringRequiredEntitlementLeavesTheErrorMessage() async throws {
        StubURLProtocol.handler = { _, _ in
            (403, Data(#"{"error":"Creator not authorized","required_entitlement":42}"#.utf8))
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
            return (200, Self.successBody(manifest: Self.manifestStore))
        }

        _ = try await makeService(accessToken: { "passkey-cwt" }).signManifest(sampleRequest())

        XCTAssertEqual(authorization, "Bearer passkey-cwt")
    }

    func testSendsNoAuthorizationWithoutAToken() async throws {
        var authorization: String?
        StubURLProtocol.handler = { request, _ in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return (200, Self.successBody(manifest: Self.manifestStore))
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

    func testRejectsAnEmptyManifest() async throws {
        StubURLProtocol.handler = { _, _ in (200, Self.successBody(manifest: Data())) }
        try await assertInvalidResponse()
    }

    func testRejectsAManifestThatIsNotAJUMBFSuperbox() async throws {
        StubURLProtocol.handler = { _, _ in (200, Self.successBody(manifest: box("free", Data(count: 16)))) }
        try await assertInvalidResponse()
    }

    func testRejectsAManifestWhoseBoxSizeDoesNotMatchItsLength() async throws {
        StubURLProtocol.handler = { _, _ in (200, Self.successBody(manifest: Self.manifestStore + Data([0]))) }
        try await assertInvalidResponse()
    }

    func testIgnoresARetryAfterThatIsNotAnIntegerNumberOfSeconds() async throws {
        for value in ["100000000000000000000", "inf", "-5", "Wed, 21 Oct 2026 07:28:00 GMT"] {
            StubURLProtocol.responseHeaders = ["Retry-After": value]
            StubURLProtocol.handler = { _, _ in (429, Data(#"{"error":"Too many signing requests"}"#.utf8)) }

            do {
                _ = try await makeService().signManifest(sampleRequest())
                XCTFail("expected rateLimited")
            } catch C2PASigningService.ServiceError.rateLimited(let retryAfter) {
                XCTAssertNil(retryAfter, value)
            }
        }
    }

    func testRateLimitedDescribesAnyDelay() {
        for delay in [TimeInterval.infinity, .nan, -1, 1e30, 30] {
            let description = C2PASigningService.ServiceError.rateLimited(retryAfter: delay).errorDescription ?? ""
            XCTAssertTrue(description.hasPrefix("Too many C2PA sign requests"), description)
        }
        XCTAssertEqual(
            C2PASigningService.ServiceError.rateLimited(retryAfter: 30).errorDescription,
            "Too many C2PA sign requests; retry in 30 s"
        )
    }

    func testRejectsASuccessResponseWithoutAManifest() async throws {
        StubURLProtocol.handler = { _, _ in (200, Data(#"{"status":"success"}"#.utf8)) }

        do {
            _ = try await makeService().signManifest(sampleRequest())
            XCTFail("expected invalidResponse")
        } catch C2PASigningService.ServiceError.invalidResponse {
        }
    }

    // MARK: - Transport

    /// The C2PA conformance program's Level 1 (O.5) asks for TLS 1.3 between Creator and arks
    func testTheDefaultSessionRefusesTLSBelow1_3() {
        XCTAssertEqual(C2PASigningService.defaultSession.configuration.tlsMinimumSupportedProtocolVersion, .TLSv13)
        XCTAssertTrue(C2PASigningService().session === C2PASigningService.defaultSession)
    }

    // MARK: - Fixtures

    /// A minimal JUMBF manifest store: one `jumb` superbox
    private static let manifestStore = manifest(carrying: .digitalCapture)

    /// A manifest store whose claim names `sourceType`, the way c2pa-rs encodes it: the
    /// full IPTC URI as a CBOR text string
    private static func manifest(carrying sourceType: C2PADigitalSourceType?) -> Data {
        var payload = Data(repeating: 0x11, count: 24)
        if let sourceType {
            let uri = Data("http://cv.iptc.org/newscodes/digitalsourcetype/\(sourceType.rawValue)".utf8)
            payload += Data([0x78, UInt8(uri.count)]) + uri + Data(repeating: 0x11, count: 8)
        }
        return box("jumb", payload)
    }

    private func assertInvalidResponse(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await makeService().signManifest(sampleRequest())
            XCTFail("expected invalidResponse", file: file, line: line)
        } catch C2PASigningService.ServiceError.invalidResponse {
        }
    }

    private func makeService(
        accessToken: C2PASigningService.AccessTokenProvider? = nil,
        deviceToken: C2PASigningService.AccessTokenProvider? = nil
    ) -> C2PASigningService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return C2PASigningService(
            serverURL: URL(string: "https://signer.test")!,
            session: URLSession(configuration: configuration),
            accessToken: accessToken,
            deviceToken: deviceToken
        )
    }

    private func sampleRequest(_ sourceType: C2PADigitalSourceType = .digitalCapture) -> C2PASignRequest {
        C2PASignRequest(
            contentHash: String(repeating: "ab", count: 32),
            exclusionRanges: [C2PAExclusionRange(start: 100, end: 245, boxType: "uuid")],
            containerFormat: .mov,
            metadata: C2PASigningMetadata(
                title: "Test Recording",
                creator: "tester@arkavo.net",
                timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                digitalSourceType: sourceType,
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
