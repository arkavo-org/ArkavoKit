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

        // Next send callback with code but NO state — must return 400 without aborting active sign-in.
        let missingStateResponse = try await Self.sendRawHTTP(
            chunks: ["GET /?code=attacker-code HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"],
            port: port
        )
        XCTAssertTrue(missingStateResponse.hasPrefix("HTTP/1.1 400"), "Expected 400 for missing state")

        // Next send callback with mismatched state — must also return 400 without aborting active sign-in.
        let wrongStateResponse = try await Self.sendRawHTTP(
            chunks: ["GET /?code=attacker-code&state=wrong-state HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"],
            port: port
        )
        XCTAssertTrue(wrongStateResponse.hasPrefix("HTTP/1.1 400"), "Expected 400 for mismatched state")

        // Legitimate callback with valid state immediately after must still succeed.
        let validResponse = try await Self.sendRawHTTP(
            chunks: ["GET /?code=legit-code&state=expected-csrf-state HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"],
            port: port
        )
        XCTAssertTrue(validResponse.hasPrefix("HTTP/1.1 200"), "Expected 200 for valid state callback")

        let code = try await waitTask.value
        XCTAssertEqual(code, "legit-code")
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
            },
            {
              "post": {
                "uri": "at://did:plc:abc/app.bsky.feed.post/456",
                "cid": "bafy456",
                "author": { "did": "did:plc:abc", "handle": "alice.bsky.social" },
                "record": { "text": "reply", "createdAt": "2026-01-01T00:00:02Z" },
                "likeCount": 7,
                "repostCount": 3,
                "indexedAt": "2026-01-01T00:00:03Z"
              },
              "reply": {
                "parent": {
                  "uri": "at://did:plc:abc/app.bsky.feed.post/123",
                  "cid": "bafy123",
                  "author": { "did": "did:plc:abc", "handle": "alice.bsky.social" },
                  "record": { "text": "hello", "createdAt": "2026-01-01T00:00:00Z" },
                  "indexedAt": "2026-01-01T00:00:01Z"
                },
                "root": {
                  "uri": "at://did:plc:abc/app.bsky.feed.post/123",
                  "cid": "bafy123",
                  "author": { "did": "did:plc:abc", "handle": "alice.bsky.social" },
                  "record": { "text": "hello", "createdAt": "2026-01-01T00:00:00Z" },
                  "indexedAt": "2026-01-01T00:00:01Z"
                }
              }
            }
          ]
        }
        """

        let timeline = try JSONDecoder().decode(TimelineResponse.self, from: Data(json.utf8))
        XCTAssertEqual(timeline.feed.count, 2)
        // Missing counts default to 0 while preserving non-optional Int API for downstream callers.
        XCTAssertEqual(timeline.feed[0].post.likeCount, 0)
        XCTAssertEqual(timeline.feed[0].post.repostCount, 0)
        // Non-post reply unions decode FeedViewPost.reply as nil without failing the timeline.
        XCTAssertNil(timeline.feed[0].reply)
        // Valid reply decodes non-optional parent and root.
        XCTAssertEqual(timeline.feed[1].post.likeCount, 7)
        XCTAssertEqual(timeline.feed[1].post.repostCount, 3)
        XCTAssertEqual(timeline.feed[1].reply?.parent.uri, "at://did:plc:abc/app.bsky.feed.post/123")
        XCTAssertEqual(timeline.feed[1].reply?.root.uri, "at://did:plc:abc/app.bsky.feed.post/123")

        // ProfileViewResponse missing counts also default to 0 as non-optional Int.
        let profileJSON = #"{"did":"did:plc:abc","handle":"alice.bsky.social"}"#
        let profile = try JSONDecoder().decode(ProfileViewResponse.self, from: Data(profileJSON.utf8))
        XCTAssertEqual(profile.followersCount, 0)
        XCTAssertEqual(profile.followsCount, 0)
        XCTAssertEqual(profile.postsCount, 0)
    }

    func testBlueskyCreatePostRequestRejectsMalformedReplyTo() throws {
        for malformed in ["|", "at://did:plc:alice/app.bsky.feed.post/1", "|bafy123", "at://did:plc:alice/app.bsky.feed.post/1|"] {
            XCTAssertThrowsError(try CreatePostRequest(did: "did:plc:alice", text: "hello", replyTo: malformed)) { error in
                XCTAssertTrue(error is BlueskyError, "Expected BlueskyError for malformed replyTo '\(malformed)', got \(error)")
            }
        }

        let valid = try CreatePostRequest(
            did: "did:plc:alice",
            text: "hello",
            replyTo: "at://did:plc:alice/app.bsky.feed.post/1|bafy123"
        )
        XCTAssertEqual(valid.record.reply?.parent, StrongRef(uri: "at://did:plc:alice/app.bsky.feed.post/1", cid: "bafy123"))
        XCTAssertEqual(valid.record.reply?.root, StrongRef(uri: "at://did:plc:alice/app.bsky.feed.post/1", cid: "bafy123"))
    }

    @MainActor
    func testBlueskyUnlikePostNeverDeletesPostRecordAndResolvesLikeURI() async throws {
        let myDID = "did:plc:alice"
        let postWithoutLike = "at://\(myDID)/app.bsky.feed.post/own-post-1"
        let likedPostURI = "at://\(myDID)/app.bsky.feed.post/post-2"
        let cachedLikeURI = "at://\(myDID)/app.bsky.feed.like/like-cached"
        let serverResolvedPostURI = "at://\(myDID)/app.bsky.feed.post/post-3"
        let serverResolvedLikeURI = "at://\(myDID)/app.bsky.feed.like/like-from-server"

        let mockHTTP = AuditMockBlueskyHTTP { url, _, _ in
            if url.path.hasSuffix("com.atproto.repo.createRecord") {
                return Data(#"{"uri":"\#(cachedLikeURI)","cid":"bafylike1"}"#.utf8)
            }
            if url.path.hasSuffix("app.bsky.feed.getPosts") {
                if url.absoluteString.contains("post-3") {
                    return Data(#"{"posts":[{"uri":"\#(serverResolvedPostURI)","viewer":{"like":"\#(serverResolvedLikeURI)"}}]}"#.utf8)
                }
                return Data(#"{"posts":[{"uri":"\#(postWithoutLike)","viewer":{}}]}"#.utf8)
            }
            if url.path.hasSuffix("com.atproto.repo.deleteRecord") {
                return Data("{}".utf8)
            }
            throw URLError(.badURL)
        }

        let client = BlueskyClient(
            httpClient: mockHTTP,
            accessTokenProvider: { "access-token" },
            didProvider: { myDID }
        )

        // 1. Passing a post URI that has no like record MUST NOT call deleteRecord on the post!
        await client.unlikePost(uri: postWithoutLike)
        XCTAssertNotNil(client.error)
        let deletesAfterUnlikedPost = mockHTTP.recorded.filter { $0.endpoint.hasSuffix("com.atproto.repo.deleteRecord") }
        XCTAssertTrue(deletesAfterUnlikedPost.isEmpty, "unlikePost must NEVER delete an app.bsky.feed.post record")

        // 2. Passing another user's like URI MUST be refused without calling deleteRecord!
        await client.unlikePost(uri: "at://did:plc:other/app.bsky.feed.like/foreign-like")
        XCTAssertNotNil(client.error)
        XCTAssertTrue(
            mockHTTP.recorded.filter { $0.endpoint.hasSuffix("com.atproto.repo.deleteRecord") }.isEmpty,
            "unlikePost must NEVER delete a like record owned by another DID"
        )

        // 3. likePost caches the created like URI; unlikePost(postURI) deletes ONLY app.bsky.feed.like/like-cached.
        await client.likePost(uri: likedPostURI, cid: "bafypost2")
        XCTAssertNil(client.error)
        await client.unlikePost(uri: likedPostURI)
        XCTAssertNil(client.error)

        // 4. Uncached post URI resolves viewer.like via getPosts and deletes ONLY app.bsky.feed.like/like-from-server.
        await client.unlikePost(uri: serverResolvedPostURI)
        XCTAssertNil(client.error)

        let deleteRequests = mockHTTP.recorded.filter { $0.endpoint.hasSuffix("com.atproto.repo.deleteRecord") }
        XCTAssertEqual(deleteRequests.count, 2)
        let decodedBodies = try deleteRequests.map { req -> [String: String] in
            let bodyData = try XCTUnwrap(req.bodyData)
            return try JSONDecoder().decode([String: String].self, from: bodyData)
        }
        for payload in decodedBodies {
            XCTAssertEqual(payload["collection"], "app.bsky.feed.like", "Expected like collection, got \(payload)")
            XCTAssertEqual(payload["repo"], myDID, "Expected current user's DID, got \(payload)")
        }
        XCTAssertEqual(decodedBodies[0]["rkey"], "like-cached")
        XCTAssertEqual(decodedBodies[1]["rkey"], "like-from-server")
    }

    func testYouTubeModerationEventAndHiddenSubscribersDecodeNonOptionalDefaults() throws {
        let chatJSON = """
        {
          "items": [
            {
              "id": "msg-mod-1",
              "snippet": {
                "type": "messageDeletedEvent",
                "publishedAt": "2026-01-01T00:00:00Z"
              },
              "authorDetails": {
                "channelId": "UC123",
                "displayName": "Mod",
                "isChatOwner": false,
                "isChatModerator": true,
                "isChatSponsor": false
              }
            }
          ]
        }
        """
        let chatResponse = try JSONDecoder().decode(YouTubeLiveChatResponse.self, from: Data(chatJSON.utf8))
        XCTAssertEqual(chatResponse.items.count, 1)
        let displayMessage: String = chatResponse.items[0].snippet.displayMessage
        XCTAssertEqual(displayMessage, "")

        let channelJSON = """
        {
          "items": [
            {
              "id": "UC123",
              "snippet": {
                "title": "Hidden Subs Channel",
                "description": "desc",
                "thumbnails": { "default": { "url": "https://example.com/thumb.png" } }
              },
              "statistics": {
                "viewCount": "42",
                "videoCount": "3"
              }
            }
          ]
        }
        """
        let channelResponse = try JSONDecoder().decode(YouTubeChannelResponse.self, from: Data(channelJSON.utf8))
        XCTAssertEqual(channelResponse.items.count, 1)
        let subscriberCount: String = channelResponse.items[0].statistics.subscriberCount
        XCTAssertEqual(subscriberCount, "0")
    }

    @MainActor
    func testYouTubeFetchChannelInfoDoesNotRestoreAfterLogout() async throws {
        let store = AuditMemoryYouTubeStore()
        store.save("access-1", for: "access_token")
        store.save("refresh-1", for: "refresh_token")
        store.save(ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)), for: "token_expiration")

        let (arrivedStream, arrivedCont) = AsyncStream.makeStream(of: Void.self)
        let (replyStream, replyCont) = AsyncStream.makeStream(of: Void.self)

        let client = YouTubeClient(
            clientId: "client",
            clientSecret: "secret",
            store: store,
            send: { request in
                arrivedCont.yield()
                for await _ in replyStream { break }
                let body = """
                {
                  "items": [
                    {
                      "id": "UC-LOGOUT-TEST",
                      "snippet": {
                        "title": "Stale Channel",
                        "description": "desc",
                        "thumbnails": { "default": { "url": "https://example.com/a.png" } }
                      },
                      "statistics": {
                        "viewCount": "10",
                        "subscriberCount": "5",
                        "videoCount": "1"
                      }
                    }
                  ]
                }
                """
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(body.utf8), resp)
            }
        )

        let fetchTask = Task {
            await client.fetchChannelInfo()
        }

        for await _ in arrivedStream { break }
        client.logout()
        replyCont.yield()

        await fetchTask.value
        XCTAssertNil(client.channelInfo, "Stale fetchChannelInfo must not publish channelInfo after logout")
        XCTAssertNil(store.value(for: "channel_id"), "Stale fetchChannelInfo must not write channel_id after logout")
    }

    @MainActor
    func testYouTubeExchangeCodeForTokensThrowsCancellationErrorAfterLogout() async throws {
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
        await client.setRedirectUriForTesting("http://127.0.0.1:8080")

        let exchangeTask = Task {
            try await client.exchangeCodeForTokens("code-1")
        }

        for await _ in arrivedStream { break }
        client.logout()
        replyCont.yield()

        do {
            try await exchangeTask.value
            XCTFail("Expected CancellationError when logout occurs during exchangeCodeForTokens")
        } catch is CancellationError {
            // expected
        }
        XCTAssertNil(store.value(for: "access_token"))
    }

    #if os(macOS)
    func testOAuthCallbackServerRejectsErrorWithoutValidState() async throws {
        let server = OAuthCallbackServer()
        let port = try server.startListening(state: "expected-csrf-state")
        defer { server.stop() }

        let waitTask = Task {
            try await server.waitForCallback(timeout: 5)
        }

        let missingStateResponse = try await Self.sendRawHTTP(
            chunks: ["GET /?error=access_denied&error_description=attacker_injected_text HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"],
            port: port
        )
        XCTAssertTrue(missingStateResponse.hasPrefix("HTTP/1.1 400"), "Expected 400 for error callback without valid state")
        XCTAssertFalse(missingStateResponse.contains("attacker_injected_text"), "Unauthenticated error text must not be reflected")

        let mismatchedStateResponse = try await Self.sendRawHTTP(
            chunks: ["GET /?error=access_denied&error_description=attacker_injected_text&state=wrong-state HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"],
            port: port
        )
        XCTAssertTrue(mismatchedStateResponse.hasPrefix("HTTP/1.1 400"), "Expected 400 for error callback with mismatched state")
        XCTAssertFalse(mismatchedStateResponse.contains("attacker_injected_text"), "Unauthenticated error text must not be reflected")

        // Forged error callbacks must NOT abort the active sign-in: the real callback must still succeed.
        let validResponse = try await Self.sendRawHTTP(
            chunks: ["GET /?code=real-auth-code&state=expected-csrf-state HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"],
            port: port
        )
        XCTAssertTrue(validResponse.hasPrefix("HTTP/1.1 200"), "Expected 200 for valid state callback after forged errors")

        let code = try await waitTask.value
        XCTAssertEqual(code, "real-auth-code")
    }
    #endif

    @MainActor
    func testRedditAndMicropubAuthURLReusePendingStateUntilLogout() throws {
        func stateQueryValue(from url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "state" })?
                .value
        }

        let reddit = RedditClient(clientId: "reddit-client")
        let redditState1 = try XCTUnwrap(stateQueryValue(from: reddit.authURL))
        let redditState2 = try XCTUnwrap(stateQueryValue(from: reddit.authURL))
        XCTAssertFalse(redditState1.isEmpty)
        XCTAssertEqual(redditState1, redditState2, "Repeated Reddit authURL reads must reuse pendingOAuthState")
        reddit.logout()
        let redditState3 = try XCTUnwrap(stateQueryValue(from: reddit.authURL))
        XCTAssertNotEqual(redditState1, redditState3, "logout() must invalidate pendingOAuthState")

        let micropub = MicropubClient(clientId: "micropub-client")
        let micropubState1 = try XCTUnwrap(stateQueryValue(from: micropub.authURL))
        let micropubState2 = try XCTUnwrap(stateQueryValue(from: micropub.authURL))
        XCTAssertFalse(micropubState1.isEmpty)
        XCTAssertEqual(micropubState1, micropubState2, "Repeated Micropub authURL reads must reuse pendingOAuthState")
        micropub.logout()
        let micropubState3 = try XCTUnwrap(stateQueryValue(from: micropub.authURL))
        XCTAssertNotEqual(micropubState1, micropubState3, "logout() must invalidate pendingOAuthState")
    }

    @MainActor
    func testBlueskyDeletePostGuardsCollectionAndDID() async throws {
        let myDID = "did:plc:alice"
        let mockHTTP = AuditMockBlueskyHTTP { url, _, _ in
            if url.path.hasSuffix("com.atproto.repo.deleteRecord") {
                return Data("{}".utf8)
            }
            throw URLError(.badURL)
        }

        let client = BlueskyClient(
            httpClient: mockHTTP,
            accessTokenProvider: { "access-token" },
            didProvider: { myDID }
        )

        // Non-post collections must be rejected without calling deleteRecord.
        await client.deletePost(uri: "at://\(myDID)/app.bsky.actor.profile/self")
        XCTAssertNotNil(client.error)
        await client.deletePost(uri: "at://\(myDID)/app.bsky.feed.like/like-1")
        XCTAssertNotNil(client.error)
        XCTAssertTrue(mockHTTP.recorded.isEmpty, "deletePost must never call deleteRecord for non-post collections")

        // Foreign DIDs must be rejected without calling deleteRecord.
        await client.deletePost(uri: "at://did:plc:bob/app.bsky.feed.post/foreign-post")
        XCTAssertNotNil(client.error)
        XCTAssertTrue(mockHTTP.recorded.isEmpty, "deletePost must never call deleteRecord for another user's DID")

        // Own app.bsky.feed.post record must succeed.
        await client.deletePost(uri: "at://\(myDID)/app.bsky.feed.post/own-post-1")
        XCTAssertNil(client.error)
        XCTAssertEqual(mockHTTP.recorded.count, 1)
        XCTAssertTrue(mockHTTP.recorded[0].endpoint.hasSuffix("com.atproto.repo.deleteRecord"))
        let bodyData = try XCTUnwrap(mockHTTP.recorded[0].bodyData)
        let payload = try JSONDecoder().decode([String: String].self, from: bodyData)
        XCTAssertEqual(payload["repo"], myDID)
        XCTAssertEqual(payload["collection"], "app.bsky.feed.post")
        XCTAssertEqual(payload["rkey"], "own-post-1")
    }

    @MainActor
    func testRedditHandleCallbackKeepsWebViewOpenOnInvalidState() throws {
        func stateQueryValue(from url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "state" })?
                .value
        }

        let reddit = RedditClient(clientId: "reddit-client")
        let expectedState = try XCTUnwrap(stateQueryValue(from: reddit.authURL))
        reddit.startOAuth()
        XCTAssertTrue(reddit.showingWebView)

        // Missing state must not dismiss the login webview or consume pendingOAuthState.
        reddit.handleCallback(URL(string: "arkavocreator://oauth/reddit?code=forged")!)
        XCTAssertTrue(reddit.showingWebView, "Callback with missing state must keep showingWebView == true")
        XCTAssertNotNil(reddit.error)

        // Mismatched state must not dismiss the login webview or consume pendingOAuthState.
        reddit.handleCallback(URL(string: "arkavocreator://oauth/reddit?code=forged&state=wrong-state")!)
        XCTAssertTrue(reddit.showingWebView, "Callback with mismatched state must keep showingWebView == true")
        XCTAssertEqual(
            stateQueryValue(from: reddit.authURL),
            expectedState,
            "Invalid-state callback must preserve pendingOAuthState"
        )

        // Valid state dismisses the webview.
        reddit.handleCallback(URL(string: "arkavocreator://oauth/reddit?error=access_denied&state=\(expectedState)")!)
        XCTAssertFalse(reddit.showingWebView, "Valid-state callback should dismiss showingWebView")
    }

    @MainActor
    func testArkavoClientDisconnectDeletesTokenAfterTearDownConnection() async {
        let client = makeTestClient()
        let store = FakeCredentialStore(token: "cached-cwt-token", handle: "alice")
        client.credentialStore = store
        client.currentState = .connected
        let session = URLSession(configuration: .ephemeral)
        client.session = session
        client.webSocket = session.webSocketTask(with: URL(string: "wss://kas.example.test")!)

        // Transport teardown (e.g., timeout/cancellation) clears socket/session while preserving Keychain token.
        client.tearDownConnection(error: ArkavoError.connectionFailed("Timed out"))
        XCTAssertEqual(client.currentState, .disconnected)
        XCTAssertNil(client.webSocket)
        XCTAssertNil(client.session)
        XCTAssertEqual(store.token, "cached-cwt-token")
        XCTAssertTrue(store.removals.isEmpty)

        // Subsequent explicit disconnect() must still delete the Keychain auth token.
        await client.disconnect()
        XCTAssertEqual(client.currentState, .disconnected)
        XCTAssertNil(store.token, "Explicit disconnect() must delete the auth token even after tearDownConnection")
        XCTAssertEqual(store.removals, ["token"])
    }

    @MainActor
    func testArkavoClientCleanUpOwnedTransportDoesNotDisturbReplacementConnection() {
        let client = makeTestClient()
        let staleSession = URLSession(configuration: .ephemeral)
        let staleSocket = staleSession.webSocketTask(with: URL(string: "wss://kas.example.test/stale")!)
        let replacementSession = URLSession(configuration: .ephemeral)
        let replacementSocket = replacementSession.webSocketTask(with: URL(string: "wss://kas.example.test/new")!)

        client.currentState = .connected
        client.session = replacementSession
        client.webSocket = replacementSocket

        client.cleanUpOwnedTransport(webSocket: staleSocket, session: staleSession)

        XCTAssertEqual(client.currentState, .connected)
        XCTAssertTrue(client.webSocket === replacementSocket, "Stale cleanup must not clear replacement webSocket")
        XCTAssertTrue(client.session === replacementSession, "Stale cleanup must not clear replacement session")

        client.cleanUpOwnedTransport(webSocket: replacementSocket, session: replacementSession)
        XCTAssertNil(client.webSocket)
        XCTAssertNil(client.session)
    }

    // MARK: - Helpers

    private struct AuditRecordedBlueskyRequest: Sendable {
        let endpoint: String
        let method: String
        let bodyData: Data?
    }

    private final class AuditMockBlueskyHTTP: HTTPClient, Sendable {
        private let lock = Mutex<[AuditRecordedBlueskyRequest]>([])
        private let handler: @Sendable (URL, String, Data?) throws -> Data

        init(handler: @escaping @Sendable (URL, String, Data?) throws -> Data) {
            self.handler = handler
        }

        var recorded: [AuditRecordedBlueskyRequest] { lock.withLock { $0 } }

        func sendRequest<T: Decodable & Sendable>(
            _ url: URL,
            method: String,
            body: (any Encodable & Sendable)?,
            headers _: [String: String]
        ) async throws -> T {
            let bodyData = try body.map { try JSONEncoder().encode($0) }
            lock.withLock {
                $0.append(AuditRecordedBlueskyRequest(endpoint: url.path, method: method, bodyData: bodyData))
            }
            let data = try handler(url, method, bodyData)
            if data.isEmpty, let empty = try? JSONDecoder().decode(T.self, from: Data("{}".utf8)) {
                return empty
            }
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

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
