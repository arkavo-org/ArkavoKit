import Compression
import Foundation
import Network
import Security
import Synchronization
import XCTest
@testable import ArkavoSocial

final class SocialAuditFixesTests: XCTestCase {

    // MARK: - Form Encoding (H6)

    func testPercentEncodedEscapesReservedFormCharacters() throws {
        let params = [
            "client_secret": "a+b&c=d/e?f:g h%20",
            "code": "4/0A+test=value&extra",
            "key+with&eq=1": "ok-._~AZaz09",
        ]

        let encodedData = params.percentEncoded()
        let body = try XCTUnwrap(String(data: encodedData, encoding: .utf8))

        let pairs = body.split(separator: "&").map(String.init)
        XCTAssertEqual(pairs.count, 3, "Embedded '&' must be percent-encoded so only 3 form pairs exist")

        var decoded: [String: String] = [:]
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 2, omittingEmptySubsequences: false)
            XCTAssertEqual(parts.count, 2, "Embedded '=' must be percent-encoded in pair: \(pair)")
            XCTAssertFalse(parts[0].contains("+"), "Key must percent-encode '+'")
            XCTAssertFalse(parts[1].contains("+"), "Value must percent-encode '+'")
            let key = try XCTUnwrap(String(parts[0]).removingPercentEncoding)
            let value = try XCTUnwrap(String(parts[1]).removingPercentEncoding)
            decoded[key] = value
        }

        XCTAssertEqual(decoded, params)
    }

    // MARK: - TDFArchiveReader Zip-Bomb Cap (C3)

    func testTDFArchiveReaderRejectsOversizedPayloadAndForgedHeader() throws {
        let rawPayload = Data(repeating: 0x41, count: 16_384)
        let normalZip = try Self.makeDeflatedZIP(entries: [
            (name: "0.payload", data: rawPayload, declaredUncompressedSize: nil),
        ])

        // Within limit succeeds
        let extracted = try TDFArchiveReader.extractPayload(from: normalZip, maxBytes: 32_768)
        XCTAssertEqual(extracted, rawPayload)

        // Exceeding declared size limit is rejected before decompression
        XCTAssertThrowsError(try TDFArchiveReader.extractPayload(from: normalZip, maxBytes: 1024)) { error in
            guard case TDFArchiveError.extractionFailed = error else {
                return XCTFail("Expected TDFArchiveError.extractionFailed, got \(error)")
            }
        }

        // Forged header claiming only 16 uncompressed bytes while stream decompresses to 16 KiB
        // must still be rejected by the streaming consumer byte limit.
        let forgedZip = try Self.makeDeflatedZIP(entries: [
            (name: "0.payload", data: rawPayload, declaredUncompressedSize: 16),
        ])
        XCTAssertThrowsError(try TDFArchiveReader.extractPayload(from: forgedZip, maxBytes: 1024)) { error in
            guard case TDFArchiveError.extractionFailed = error else {
                return XCTFail("Expected TDFArchiveError.extractionFailed for forged header, got \(error)")
            }
        }
    }

    // MARK: - YouTubeClient Range Header & Resumable Upload (C12, H12, Logout Resurrection)

    func testNextOffsetFromRangeHeaderEdgeCases() {
        XCTAssertNil(YouTubeClient.nextOffsetFromRangeHeader(nil))
        XCTAssertNil(YouTubeClient.nextOffsetFromRangeHeader(""))
        XCTAssertNil(YouTubeClient.nextOffsetFromRangeHeader("bytes=0-"))
        XCTAssertNil(YouTubeClient.nextOffsetFromRangeHeader("bytes=0--5"))
        XCTAssertNil(YouTubeClient.nextOffsetFromRangeHeader("bytes=10-20"))
        XCTAssertNil(YouTubeClient.nextOffsetFromRangeHeader("bytes=0-\(Int64.max)"))
        XCTAssertEqual(YouTubeClient.nextOffsetFromRangeHeader("bytes=0-0"), 1)
        XCTAssertEqual(YouTubeClient.nextOffsetFromRangeHeader("bytes=0-1023"), 1024)
        XCTAssertEqual(YouTubeClient.nextOffsetFromRangeHeader(" bytes=0-4095 "), 4096)
    }

    func testResumableUploadReReadsChunkWhenProbeAdvancesOffsetAfterTransientError() async throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("yt-c12-\(UUID().uuidString).bin")
        let payload = Data((0 ..< 16).map { UInt8($0) })
        try payload.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let recordedRanges = Mutex<[String]>([])
        let recordedBodies = Mutex<[Data]>([])
        let step = Mutex<Int>(0)

        let uploadSend: YouTubeSend = { request in
            let currentStep = step.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            let contentRange = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            let body = request.httpBody ?? Data()
            recordedRanges.withLock { $0.append(contentRange) }
            recordedBodies.withLock { $0.append(body) }

            let url = request.url!
            switch currentStep {
            case 0:
                // Initial chunk 0-15/16 fails with transient 503
                let resp = HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(), resp)
            case 1:
                // Probe request: server committed first 8 bytes (0..7)
                XCTAssertEqual(contentRange, "bytes */16")
                let resp = HTTPURLResponse(
                    url: url,
                    statusCode: 308,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Range": "bytes=0-7"]
                )!
                return (Data(), resp)
            case 2:
                // Retry MUST send only bytes 8..15 with matching Content-Range & body
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(#"{"id":"video-c12"}"#.utf8), resp)
            default:
                XCTFail("Unexpected upload step \(currentStep)")
                let resp = HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(), resp)
            }
        }

        let client = YouTubeClient(
            clientId: "client",
            clientSecret: "secret",
            store: AuditMemoryYouTubeStore(),
            send: { _ in throw URLError(.badURL) },
            uploadSend: uploadSend,
            uploadRetryBaseSeconds: 0
        )

        let videoId = try await client.uploadResumableChunks(
            to: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=1")!,
            fileURL: tempFile,
            totalSize: Int64(payload.count),
            mimeType: "video/mp4",
            onProgress: nil
        )

        XCTAssertEqual(videoId, "video-c12")
        let ranges = recordedRanges.withLock { $0 }
        let bodies = recordedBodies.withLock { $0 }
        XCTAssertEqual(ranges, ["bytes 0-15/16", "bytes */16", "bytes 8-15/16"])
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(bodies[0], payload)
        XCTAssertEqual(bodies[2], Data(payload[8 ..< 16]), "Retry after partial probe must re-read from offset 8")
    }

    func testResumableUpload308WithoutRangeDoesNotSkipBytesAndCapsStalledRetries() async throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("yt-h12-\(UUID().uuidString).bin")
        let payload = Data(repeating: 0x5A, count: 16)
        try payload.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let seenRanges = Mutex<[String]>([])
        let uploadSend: YouTubeSend = { request in
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            seenRanges.withLock { $0.append(range) }
            // 308 with NO Range header -> 0 bytes committed
            let resp = HTTPURLResponse(url: request.url!, statusCode: 308, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(), resp)
        }

        let client = YouTubeClient(
            clientId: "client",
            clientSecret: "secret",
            store: AuditMemoryYouTubeStore(),
            send: { _ in throw URLError(.badURL) },
            uploadSend: uploadSend,
            uploadRetryBaseSeconds: 0
        )

        do {
            _ = try await client.uploadResumableChunks(
                to: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=2")!,
                fileURL: tempFile,
                totalSize: Int64(payload.count),
                mimeType: "video/mp4",
                onProgress: nil
            )
            XCTFail("Repeated non-advancing 308 responses must fail instead of looping or skipping bytes")
        } catch {
            // Expected bounded failure
        }

        let ranges = seenRanges.withLock { $0 }
        XCTAssertGreaterThanOrEqual(ranges.count, 2)
        XCTAssertLessThanOrEqual(ranges.count, 6)
        XCTAssertTrue(ranges.allSatisfy { $0 == "bytes 0-15/16" }, "Must keep retrying from offset 0, got \(ranges)")
    }

    @MainActor
    func testYouTubeLogoutDuringSignInCodeExchangeDoesNotResurrectSession() async throws {
        let store = AuditMemoryYouTubeStore()
        let (arrivedStream, arrivedCont) = AsyncStream.makeStream(of: Void.self)
        let (replyStream, replyCont) = AsyncStream.makeStream(of: Void.self)

        let client = YouTubeClient(
            clientId: "client",
            clientSecret: "secret",
            store: store,
            send: { request in
                arrivedCont.yield()
                for await _ in replyStream { break }
                let body = #"{"access_token":"a1","expires_in":3600,"refresh_token":"r1","scope":"s","token_type":"Bearer"}"#
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(body.utf8), resp)
            }
        )

        let signInTask = Task {
            try await client.completeSignIn(code: "auth-code", redirectUri: "http://127.0.0.1:8080")
        }

        for await _ in arrivedStream { break }
        client.logout()
        replyCont.yield()

        try await signInTask.value
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNil(store.value(for: "access_token"))
        XCTAssertNil(store.value(for: "refresh_token"))
    }

    // MARK: - OAuthCallbackServer (H2, H3, H4, M1, M2)

    #if os(macOS)
    func testOAuthCallbackServerHTMLEscapingPreventsXSS() {
        let raw = #"<script>alert("xss" & '1')</script>"#
        let escaped = OAuthCallbackServer.htmlEscape(raw)
        XCTAssertEqual(escaped, "&lt;script&gt;alert(&quot;xss&quot; &amp; &#39;1&#39;)&lt;/script&gt;")
        XCTAssertFalse(escaped.contains("<"))
        XCTAssertFalse(escaped.contains(">"))
    }

    func testOAuthCallbackServerRejectsMissingStateAndIgnoresFavicon() async throws {
        let server = OAuthCallbackServer()
        let port = try server.startListening(state: "expected-csrf-state")
        defer { server.stop() }

        let waitTask = Task {
            try await server.waitForCallback(timeout: 5)
        }

        // First send /favicon.ico — server should return 404 and keep waiting.
        let faviconResponse = try await Self.sendRawHTTP(
            chunks: ["GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"],
            port: port
        )
        XCTAssertTrue(faviconResponse.hasPrefix("HTTP/1.1 404"), "Expected 404 for favicon, got: \(faviconResponse)")

        // Next send callback with code but NO state — must reject with .stateMismatch.
        let missingStateResponse = try await Self.sendRawHTTP(
            chunks: ["GET /?code=attacker-code HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"],
            port: port
        )
        XCTAssertTrue(missingStateResponse.hasPrefix("HTTP/1.1 400"), "Expected 400 for missing state")

        do {
            _ = try await waitTask.value
            XCTFail("Missing state parameter must be rejected")
        } catch OAuthCallbackServer.OAuthError.stateMismatch {
            // expected
        }
    }

    func testOAuthCallbackServerHandlesFragmentedHTTPRequest() async throws {
        let server = OAuthCallbackServer()
        let port = try server.startListening(state: "frag-state-123")
        defer { server.stop() }

        let waitTask = Task {
            try await server.waitForCallback(timeout: 5)
        }

        let response = try await Self.sendRawHTTP(
            chunks: [
                "GET /?code=frag-code&st",
                "ate=frag-state-123 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n",
                "Connection: close\r\n\r\n",
            ],
            port: port
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))

        let code = try await waitTask.value
        XCTAssertEqual(code, "frag-code")
    }
    #endif

    // MARK: - TDFManifestLite Validation (L4)

    func testTDFManifestLiteValidation() throws {
        func makeManifest(
            kasURL: String = "https://kas.arkavo.net",
            wrappedKey: String = Data("wrapped".utf8).base64EncodedString(),
            algorithm: String = "AES-128-CBC",
            iv: String = Data(repeating: 1, count: 16).base64EncodedString(),
            assetId: String = "asset-123",
            protectedAt: String = "2026-01-01T00:00:00Z"
        ) -> [String: Any] {
            [
                "encryptionInformation": [
                    "method": [
                        "algorithm": algorithm,
                        "iv": iv,
                    ],
                    "keyAccess": [
                        [
                            "url": kasURL,
                            "wrappedKey": wrappedKey,
                        ],
                    ],
                ],
                "meta": [
                    "assetId": assetId,
                    "protectedAt": protectedAt,
                ],
            ]
        }

        // Valid HTTPS and loopback HTTP succeed
        let validHTTPS = try TDFManifestLite.from(manifestJSON: makeManifest())
        XCTAssertEqual(validHTTPS.kasURL, "https://kas.arkavo.net")
        XCTAssertEqual(validHTTPS.assetID, "asset-123")

        let validLoopback = try TDFManifestLite.from(manifestJSON: makeManifest(kasURL: "http://127.0.0.1:8080"))
        XCTAssertEqual(validLoopback.kasURL, "http://127.0.0.1:8080")

        // Non-loopback plaintext HTTP rejected
        XCTAssertThrowsError(try TDFManifestLite.from(manifestJSON: makeManifest(kasURL: "http://kas.example.com")))
        // Malformed URL rejected
        XCTAssertThrowsError(try TDFManifestLite.from(manifestJSON: makeManifest(kasURL: "not-a-url")))
        // Empty assetId rejected
        XCTAssertThrowsError(try TDFManifestLite.from(manifestJSON: makeManifest(assetId: "   ")))
        // Empty algorithm rejected
        XCTAssertThrowsError(try TDFManifestLite.from(manifestJSON: makeManifest(algorithm: "")))
        // Invalid base64 wrappedKey and iv rejected
        XCTAssertThrowsError(try TDFManifestLite.from(manifestJSON: makeManifest(wrappedKey: "!!!not-base64!!!")))
        XCTAssertThrowsError(try TDFManifestLite.from(manifestJSON: makeManifest(iv: "")))
    }

    // MARK: - Keychain DID Query (H8), Micropub Endpoint (H18), CreatorProfile (M18), Bluesky ReplyRef (M17)

    func testDIDKeyDeletionQueryIncludesSecureEnclaveAndDataProtectionOnMacOS() {
        let query = KeychainManager.didKeyDeletionQuery()
        XCTAssertEqual(query[kSecAttrTokenID as String] as? String, kSecAttrTokenIDSecureEnclave as String)
        #if os(macOS)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        #endif
    }

    func testMicropubEndpointValidation() throws {
        XCTAssertEqual(try MicropubClient.validatedEndpointURL("https://micro.blog/micropub").host, "micro.blog")
        XCTAssertEqual(try MicropubClient.validatedEndpointURL("http://127.0.0.1:9000/micropub").host, "127.0.0.1")
        XCTAssertThrowsError(try MicropubClient.validatedEndpointURL("http://micro.blog/micropub"))
        XCTAssertThrowsError(try MicropubClient.validatedEndpointURL("not a url"))
    }

    func testCreatorProfileEquatableComparesAllFields() {
        let id = UUID()
        let a = CreatorProfile(id: id, displayName: "Alice", bio: "Original")
        var b = a
        XCTAssertEqual(a, b)
        b.displayName = "Alice Updated"
        XCTAssertNotEqual(a, b)
    }

    func testBlueskyTimelineDecodesOptionalCountsAndNonPostReplyRef() throws {
        let json = """
        {
          "feed": [
            {
              "post": {
                "uri": "at://did:plc:abc/app.bsky.feed.post/123",
                "cid": "bafy123",
                "author": { "did": "did:plc:abc", "handle": "alice.bsky.social" },
                "record": { "text": "hello", "createdAt": "2026-01-01T00:00:00Z" },
                "indexedAt": "2026-01-01T00:00:01Z"
              },
              "reply": {
                "parent": { "$type": "app.bsky.feed.defs#notFoundPost", "uri": "at://did:plc:x/app.bsky.feed.post/1", "notFound": true },
                "root": { "$type": "app.bsky.feed.defs#blockedPost", "uri": "at://did:plc:x/app.bsky.feed.post/0", "blocked": true }
              }
            }
          ]
        }
        """

        let timeline = try JSONDecoder().decode(TimelineResponse.self, from: Data(json.utf8))
        XCTAssertEqual(timeline.feed.count, 1)
        XCTAssertNil(timeline.feed[0].post.likeCount)
        XCTAssertNil(timeline.feed[0].post.repostCount)
        XCTAssertNil(timeline.feed[0].reply?.parent)
        XCTAssertNil(timeline.feed[0].reply?.root)
    }

    // MARK: - Helpers

    private final class AuditMemoryYouTubeStore: YouTubeSessionStore {
        private let storage = Mutex<[String: String]>([:])
        func value(for account: String) -> String? { storage.withLock { $0[account] } }
        func save(_ value: String, for account: String) { storage.withLock { $0[account] = value } }
        func delete(_ account: String) { storage.withLock { $0[account] = nil } }
    }

    /// Builds a minimal valid ZIP archive with raw-DEFLATE entries (and optional forged uncompressed size).
    private static func makeDeflatedZIP(
        entries: [(name: String, data: Data, declaredUncompressedSize: UInt32?)]
    ) throws -> Data {
        var archive = Data()
        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let compressed = try rawDeflate(entry.data)
            let crc = crc32(entry.data)
            let declaredSize = entry.declaredUncompressedSize ?? UInt32(entry.data.count)
            let localOffset = UInt32(archive.count)

            // Local file header
            archive.appendLE(UInt32(0x04034B50))
            archive.appendLE(UInt16(20)) // version needed
            archive.appendLE(UInt16(0)) // flags
            archive.appendLE(UInt16(8)) // compression method: deflate
            archive.appendLE(UInt16(0)) // mod time
            archive.appendLE(UInt16(0)) // mod date
            archive.appendLE(crc)
            archive.appendLE(UInt32(compressed.count))
            archive.appendLE(declaredSize)
            archive.appendLE(UInt16(nameData.count))
            archive.appendLE(UInt16(0)) // extra length
            archive.append(nameData)
            archive.append(compressed)

            // Central directory header
            centralDirectory.appendLE(UInt32(0x02014B50))
            centralDirectory.appendLE(UInt16(0x0314)) // version made by: Unix
            centralDirectory.appendLE(UInt16(20)) // version needed
            centralDirectory.appendLE(UInt16(0)) // flags
            centralDirectory.appendLE(UInt16(8)) // deflate
            centralDirectory.appendLE(UInt16(0)) // mod time
            centralDirectory.appendLE(UInt16(0)) // mod date
            centralDirectory.appendLE(crc)
            centralDirectory.appendLE(UInt32(compressed.count))
            centralDirectory.appendLE(declaredSize)
            centralDirectory.appendLE(UInt16(nameData.count))
            centralDirectory.appendLE(UInt16(0)) // extra length
            centralDirectory.appendLE(UInt16(0)) // comment length
            centralDirectory.appendLE(UInt16(0)) // disk start
            centralDirectory.appendLE(UInt16(0)) // internal attrs
            centralDirectory.appendLE(UInt32(0o100644 << 16)) // external attrs: regular file
            centralDirectory.appendLE(localOffset)
            centralDirectory.append(nameData)

            entryCount += 1
        }

        let cdOffset = UInt32(archive.count)
        let cdSize = UInt32(centralDirectory.count)
        archive.append(centralDirectory)

        // End of central directory record
        archive.appendLE(UInt32(0x06054B50))
        archive.appendLE(UInt16(0)) // disk number
        archive.appendLE(UInt16(0)) // start disk
        archive.appendLE(entryCount)
        archive.appendLE(entryCount)
        archive.appendLE(cdSize)
        archive.appendLE(cdOffset)
        archive.appendLE(UInt16(0)) // comment length

        return archive
    }

    private static func rawDeflate(_ input: Data) throws -> Data {
        let dstCapacity = max(input.count + 64, 128)
        var dst = Data(count: dstCapacity)
        let compressedSize: Int = input.withUnsafeBytes { srcPtr in
            dst.withUnsafeMutableBytes { dstPtr in
                guard let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dstBase = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return 0 }
                return compression_encode_buffer(
                    dstBase, dstCapacity,
                    srcBase, input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard compressedSize > 0 else {
            throw NSError(domain: "SocialAuditFixesTests", code: -1)
        }
        return dst.prefix(compressedSize)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~crc
    }

    #if os(macOS)
    private static func sendRawHTTP(chunks: [String], port: UInt16) async throws -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw URLError(.badURL)
        }
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "test.oauth-raw-http")

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex<Bool>(false)

            @Sendable func finish(_ result: Result<String, Error>) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(with: result)
            }

            @Sendable func readMore(accumulated: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, error in
                    var buffer = accumulated
                    if let data { buffer.append(data) }
                    if let error {
                        if buffer.isEmpty {
                            finish(.failure(error))
                        } else {
                            finish(.success(String(decoding: buffer, as: UTF8.self)))
                        }
                        return
                    }
                    if isComplete || data == nil {
                        finish(.success(String(decoding: buffer, as: UTF8.self)))
                    } else {
                        readMore(accumulated: buffer)
                    }
                }
            }

            @Sendable func sendChunks(index: Int) {
                if index >= chunks.count {
                    readMore(accumulated: Data())
                    return
                }
                connection.send(content: Data(chunks[index].utf8), completion: .contentProcessed { error in
                    if let error {
                        finish(.failure(error))
                        return
                    }
                    if index + 1 < chunks.count {
                        queue.asyncAfter(deadline: .now() + 0.02) {
                            sendChunks(index: index + 1)
                        }
                    } else {
                        readMore(accumulated: Data())
                    }
                })
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    sendChunks(index: 0)
                case let .failed(error):
                    finish(.failure(error))
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                finish(.failure(URLError(.timedOut)))
            }
        }
    }
    #endif
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
