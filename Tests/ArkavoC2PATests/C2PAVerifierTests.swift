import CryptoKit
import XCTest
@testable import ArkavoC2PA

/// Reading a signed file back: find the manifest box, send the manifest store and the
/// hash of the rest of the file to arkavo-rs `POST /c2pa/v1/validate`.
final class C2PAVerifierTests: XCTestCase {
    private var directory: URL!
    private var requests: [(URLRequest, Data?)] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("C2PAVerifierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        requests = []
        StubURLProtocol.handler = { [unowned self] request, body in
            requests.append((request, body))
            return (200, Self.validBody)
        }
    }

    override func tearDownWithError() throws {
        StubURLProtocol.handler = nil
        StubURLProtocol.responseHeaders = [:]
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - No manifest

    func testAFileWithoutAManifestIsNoManifestWithoutARequest() async throws {
        let unsigned = try write("plain.mov", makeMovie(payloadSize: 300, moovFirst: false).bytes)

        XCTAssertFalse(try C2PAVerifier.hasManifest(unsigned))
        let result = try await verifier().verify(unsigned)

        XCTAssertEqual(result, .noManifest)
        XCTAssertTrue(requests.isEmpty, "no manifest means no network call")
    }

    func testHasManifestFindsTheBoxTheSignerWrote() async throws {
        let signed = try await sign("in.mov", jumbf: Self.manifestStore(200))

        XCTAssertTrue(try C2PAVerifier.hasManifest(signed))
        XCTAssertTrue(requests.isEmpty, "hasManifest is a local check")
    }

    // MARK: - Request

    func testVerifySendsTheManifestStoreAndTheHashOfTheBytesOutsideTheBox() async throws {
        // The signer pads the store to its 4096-byte reservation; only the store is sent.
        let jumbf = Self.manifestStore(200)
        let signed = try await sign("in.mov", jumbf: jumbf, reservation: 4096)

        _ = try await verifier().verify(signed)

        let (request, body) = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://signer.test/c2pa/v1/validate")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: String])
        XCTAssertEqual(json["manifest"].flatMap { Data(base64Encoded: $0) }, jumbf)

        let bytes = try Data(contentsOf: signed)
        let box = try XCTUnwrap(Self.manifestBoxRange(in: bytes))
        XCTAssertEqual(box.count, 4096)
        XCTAssertEqual(json["content_hash"], Self.sha256Hex(bytes, excluding: box))
    }

    func testATamperedMediaByteChangesTheHashSent() async throws {
        let signed = try await sign("in.mov", jumbf: Self.manifestStore(200))
        _ = try await verifier().verify(signed)

        var bytes = try Data(contentsOf: signed)
        let mdat = try XCTUnwrap(mdatPayloadRange(bytes))
        bytes[mdat.lowerBound + 10] ^= 0xFF
        let tampered = try write("tampered.mov", bytes)
        _ = try await verifier().verify(tampered)

        guard requests.count == 2 else { return XCTFail("expected 2 validate requests, got \(requests.count)") }
        XCTAssertNotEqual(try contentHash(of: requests[0]), try contentHash(of: requests[1]))
        XCTAssertEqual(try contentHash(of: requests[1]), Self.sha256Hex(bytes, excluding: try XCTUnwrap(Self.manifestBoxRange(in: bytes))))
    }

    func testVerifiesMovMp4AndM4a() async throws {
        for ext in ["mov", "mp4", "m4a"] {
            let signed = try await sign("in.\(ext)", jumbf: Self.manifestStore(64))
            guard case .valid = try await verifier().verify(signed) else {
                return XCTFail("expected .valid for .\(ext)")
            }
        }
        XCTAssertEqual(requests.count, 3)
    }

    func testAMalformedManifestBoxIsInvalidWithoutARequest() async throws {
        // A C2PA box whose payload is not a JUMBF manifest store
        let movie = makeMovie(payloadSize: 64, moovFirst: false)
        let input = try write("in.mov", movie.bytes)
        let output = directory.appendingPathComponent("signed.mov")
        _ = try await C2PAServerSigner(reservation: 1024) { _ in Data(repeating: 0x42, count: 100) }
            .sign(inputFile: input, outputFile: output, metadata: metadata())

        let result = try await verifier().verify(output)

        guard case .invalid(let errors, _) = result else { return XCTFail("expected .invalid, got \(result)") }
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: - Response

    func testAValidResponseCarriesTheProvenance() async throws {
        let signed = try await sign("in.mov", jumbf: Self.manifestStore(64))

        let result = try await verifier().verify(signed)

        let expected = C2PAProvenance(
            creator: "arkavo:0715eaff",
            signedAt: Date(timeIntervalSince1970: 1_792_949_401),
            signedAtText: "2026-10-25T17:30:01+00:00",
            aiGenerated: false,
            actions: [C2PAProvenanceAction(
                action: "created",
                actor: "arkavo:0715eaff",
                timestamp: "2026-10-25T17:30:00Z",
                software: "Arkavo Creator 1.1"
            )]
        )
        XCTAssertEqual(result, .valid(expected))
    }

    func testAnInvalidResponseCarriesTheErrors() async throws {
        let signed = try await sign("in.mov", jumbf: Self.manifestStore(64))
        StubURLProtocol.handler = { _, _ in
            (200, Data(#"{"valid":false,"errors":["Hash mismatch: expected aa, got bb"],"creator":"arkavo:x"}"#.utf8))
        }

        let result = try await verifier().verify(signed)

        XCTAssertEqual(result, .invalid(
            errors: ["Hash mismatch: expected aa, got bb"],
            provenance: C2PAProvenance(creator: "arkavo:x")
        ))
    }

    func testAnUnparseableSigningTimeKeepsItsText() async throws {
        let signed = try await sign("in.mov", jumbf: Self.manifestStore(64))
        StubURLProtocol.handler = { _, _ in
            (200, Data(#"{"valid":true,"errors":[],"signed_at":"sometime"}"#.utf8))
        }

        guard case .valid(let provenance) = try await verifier().verify(signed) else { return XCTFail("expected .valid") }
        XCTAssertNil(provenance.signedAt)
        XCTAssertEqual(provenance.signedAtText, "sometime")
    }

    func testServerErrorsThrow() async throws {
        let signed = try await sign("in.mov", jumbf: Self.manifestStore(64))

        StubURLProtocol.handler = { _, _ in (500, Data(#"{"error":"boom"}"#.utf8)) }
        do {
            _ = try await verifier().verify(signed)
            XCTFail("expected server error")
        } catch C2PASigningService.ServiceError.server(let status, let message) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(message, "boom")
        }

        StubURLProtocol.handler = { _, _ in (200, Data("not json".utf8)) }
        do {
            _ = try await verifier().verify(signed)
            XCTFail("expected invalidResponse")
        } catch C2PASigningService.ServiceError.invalidResponse {
        }
    }

    // MARK: - Helpers

    private func verifier() -> C2PAVerifier {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return C2PAVerifier(serverURL: URL(string: "https://signer.test")!, session: URLSession(configuration: configuration))
    }

    private func sign(_ name: String, jumbf: Data, reservation: Int = 2048) async throws -> URL {
        let input = try write(name, makeMovie(payloadSize: 300, moovFirst: false).bytes)
        let output = directory.appendingPathComponent("signed-\(name)")
        _ = try await C2PAServerSigner(reservation: reservation) { _ in jumbf }
            .sign(inputFile: input, outputFile: output, metadata: metadata())
        return output
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func metadata() -> C2PASigningMetadata {
        C2PASigningMetadata(title: "Test", creator: "tester", timestamp: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func contentHash(of request: (URLRequest, Data?)) throws -> String? {
        let json = try JSONSerialization.jsonObject(with: XCTUnwrap(request.1)) as? [String: String]
        return json?["content_hash"]
    }

    private func mdatPayloadRange(_ data: Data) -> Range<Int>? {
        var offset = 0
        while offset + 8 <= data.count {
            let size = Int(data.subdata(in: offset..<offset + 4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: data.subdata(in: offset + 4..<offset + 8), as: UTF8.self)
            if type == "mdat" { return offset + 8..<offset + size }
            guard size >= 8 else { return nil }
            offset += size
        }
        return nil
    }

    /// The C2PA `uuid` box: the top-level box right after `ftyp`
    private static func manifestBoxRange(in data: Data) -> Range<Int>? {
        let ftypSize = Int(data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        let size = Int(data.subdata(in: ftypSize..<ftypSize + 4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard String(decoding: data.subdata(in: ftypSize + 4..<ftypSize + 8), as: UTF8.self) == "uuid" else { return nil }
        return ftypSize..<ftypSize + size
    }

    private static func sha256Hex(_ data: Data, excluding range: Range<Int>) -> String {
        var hasher = SHA256()
        hasher.update(data: data.prefix(range.lowerBound))
        hasher.update(data: data.dropFirst(range.upperBound))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A JUMBF manifest store: one `jumb` superbox with `payload` bytes
    private static func manifestStore(_ payload: Int) -> Data {
        box("jumb", Data((0..<payload).map { UInt8(truncatingIfNeeded: $0 &* 7) }))
    }

    private static let validBody = Data(#"""
    {"valid":true,"errors":[],"creator":"arkavo:0715eaff",
     "provenance_chain":[{"action":"created","actor":"arkavo:0715eaff","timestamp":"2026-10-25T17:30:00Z","software":"Arkavo Creator 1.1"}],
     "ai_generated":false,"signed_at":"2026-10-25T17:30:01+00:00"}
    """#.utf8)
}
