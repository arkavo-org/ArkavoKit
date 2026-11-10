import CryptoKit
import XCTest
@testable import ArkavoSocial

/// The game-server token (authnz-rs #151, `docs/game-token.md` at 699d1c2): the
/// byte-exact messages, what each identity answer to a mint does, and the
/// request proof. A mint never ends the session: only the renewal it asks for can.
@MainActor
final class GameTokenTests: XCTestCase {
    private static let identity = URL(string: "https://identity.example.test")!
    private static let audience = "https://game.example"
    private static let sub = "0a1b2c3d-0000-4000-8000-000000000001"
    private static let sessionID = "0f0e0d0c-0b0a-8908-8706-050403020100"
    /// The server's vector time (authnz-rs `game_token.rs`, `the_signed_messages_are_byte_exact`).
    private static let now: Int64 = 1_794_268_800
    private static let minted =
        #"{"token":"Z2FtZS10b2tlbg","expiresAt":1794269700,"onlinePlay":true,"serverTime":1794268800}"#
    private static let renewed =
        #"{"token":"renewed-token","expiresAt":1794269700,"credential":"2.c2Vjb25k","sessionExpiresAt":1794355200}"#

    private var store: InMemorySessionStore!
    private var clock: TestClock!
    private var sessions: PasskeySessions!

    override func setUp() async throws {
        store = InMemorySessionStore()
        clock = TestClock(Date(timeIntervalSince1970: TimeInterval(Self.now)))
        sessions = PasskeySessions(store: store, keys: SoftwareSessionKeys(), now: clock.read)
    }

    private func endpoint(_ http: ScriptedHTTP) -> PasskeySessionEndpoint {
        PasskeySessionEndpoint(identity: Self.identity, send: http.perform)
    }

    /// A stored session last renewed `renewedAgo` seconds ago (nil: a record from before this release).
    @discardableResult
    private func installSession(renewedAgo: TimeInterval? = 0) -> P256.Signing.PrivateKey {
        let key = P256.Signing.PrivateKey()
        store.record = PasskeySessionRecord(
            sessionId: Self.sessionID,
            credential: "1.Zmlyc3Q",
            deviceKey: key.rawRepresentation,
            account: Self.sub,
            renewedAt: renewedAgo.map { clock.now.addingTimeInterval(-$0) },
            idleTimeoutSeconds: renewedAgo == nil ? nil : 3960
        )
        return key
    }

    private static func body(of request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func verifies(_ signatureB64: String?, by publicKey: P256.Signing.PublicKey, over message: String) -> Bool {
        guard let signatureB64,
              let raw = Data(base64URLEncoded: signatureB64),
              raw.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw)
        else { return false }
        return publicKey.isValidSignature(signature, for: Data(message.utf8))
    }

    private func assertMint(
        throws expected: GameTokenError,
        via http: ScriptedHTTP,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await sessions.gameToken(audience: Self.audience, via: endpoint(http))
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as GameTokenError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    private func assertProof(
        throws expected: GameTokenError,
        method: String = "GET",
        audience: String = GameTokenTests.audience,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let token = GameToken(token: "abc", audience: audience, expiresAt: clock.now, onlinePlay: true)
        do {
            _ = try await sessions.gameRequestProof(
                for: token, method: method, url: URL(string: "https://game.example/v1/war")!, body: nil
            )
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as GameTokenError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Messages

    func testMessagesAreTheServersVectors() {
        XCTAssertEqual(
            GameTokenMessage.mint(sessionId: Self.sessionID, audience: "https://game.example", issuedAt: 1_794_268_800),
            "arkavo-game-token-v1\n0f0e0d0c-0b0a-8908-8706-050403020100\nhttps://game.example\n1794268800"
        )
        // SHA-256 of the empty string, and of "abc".
        XCTAssertEqual(
            GameTokenMessage.request(
                audience: "https://game.example",
                method: "POST",
                target: "/v1/runs?war=7",
                t: 1_794_268_800,
                body: Data(),
                token: "abc"
            ),
            "arkavo-game-request-v1\nhttps://game.example\nPOST\n/v1/runs?war=7\n1794268800\n"
                + "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU\n"
                + "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"
        )
    }

    func testTheTargetIsThePathAndQueryAsSent() {
        func target(_ url: String) -> String? { GameTokenMessage.target(of: URL(string: url)!) }
        XCTAssertEqual(target("https://game.example/v1/runs?war=7"), "/v1/runs?war=7")
        XCTAssertEqual(target("https://game.example/v1/runs"), "/v1/runs")
        XCTAssertEqual(target("https://game.example"), "/", "an empty path is /")
        XCTAssertEqual(target("https://game.example?war=7"), "/?war=7")
        XCTAssertEqual(target("https://game.example/a%20b?q=%2F#frag"), "/a%20b?q=%2F", "still percent-encoded, no fragment")
    }

    // MARK: - Mint

    func testMintSendsASignedRequestAndReturnsTheToken() async throws {
        let key = installSession()
        let before = store.record
        let http = ScriptedHTTP([.status(200, Self.minted)])

        let token = try await sessions.gameToken(audience: Self.audience, via: endpoint(http))

        XCTAssertEqual(token, GameToken(
            token: "Z2FtZS10b2tlbg",
            audience: Self.audience,
            expiresAt: Date(timeIntervalSince1970: 1_794_269_700),
            onlinePlay: true
        ))
        XCTAssertNil(token.renewedSession)

        XCTAssertEqual(http.requests.count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://identity.example.test/game/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Auth-Token"))

        let body = Self.body(of: request)
        XCTAssertEqual(Set(body.keys), ["sessionId", "audience", "issuedAt", "signature"])
        XCTAssertEqual(body["sessionId"] as? String, Self.sessionID)
        XCTAssertEqual(body["audience"] as? String, Self.audience)
        // A JSON integer, the same number the signed line carries.
        let raw = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(raw.contains(#""issuedAt":1794268800"#) && !raw.contains("1794268800."), raw)
        XCTAssertTrue(Self.verifies(
            body["signature"] as? String,
            by: key.publicKey,
            over: GameTokenMessage.mint(sessionId: Self.sessionID, audience: Self.audience, issuedAt: Self.now)
        ))
        XCTAssertEqual(store.record, before, "a mint writes nothing to the session")
    }

    func testMintWithoutASessionSendsNothing() async {
        let http = ScriptedHTTP([.status(200, Self.minted)])

        await assertMint(throws: .noSession, via: http)

        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAnAudienceThatWouldAddOrEmptyALineSendsNothing() async {
        installSession()
        for audience in ["", "https://game.example\n1", "https://game.example\r"] {
            let http = ScriptedHTTP([.status(200, Self.minted)])
            do {
                _ = try await sessions.gameToken(audience: audience, via: endpoint(http))
                XCTFail("expected invalidRequest")
            } catch {
                XCTAssertEqual(error as? GameTokenError, .invalidRequest)
            }
            XCTAssertTrue(http.requests.isEmpty)
        }
    }

    func testAnAnswerWithoutServerTimeStillMints() async throws {
        installSession()
        let http = ScriptedHTTP([.status(200, #"{"token":"t","expiresAt":1794269700,"onlinePlay":false}"#)])

        let token = try await sessions.gameToken(audience: Self.audience, via: endpoint(http))

        XCTAssertEqual(token.token, "t")
        XCTAssertFalse(token.onlinePlay)
    }

    // MARK: - 401: renew, then once more

    func testA401RenewsTheSessionAndMintsOnceMore() async throws {
        let key = installSession()
        let http = ScriptedHTTP([
            .status(401, #"{"error":"unauthorized"}"#),
            .status(200, Self.renewed),
            .status(200, Self.minted),
        ])

        let token = try await sessions.gameToken(audience: Self.audience, via: endpoint(http))

        XCTAssertEqual(http.requests.map(\.url?.path), ["/game/token", "/session/refresh", "/game/token"])
        XCTAssertEqual(token.token, "Z2FtZS10b2tlbg")
        XCTAssertEqual(token.renewedSession?.token, "renewed-token", "the app stores the renewal's auth token")
        XCTAssertEqual(store.record?.credential, "2.c2Vjb25k")
        XCTAssertTrue(Self.verifies(
            Self.body(of: http.requests[2])["signature"] as? String,
            by: key.publicKey,
            over: GameTokenMessage.mint(sessionId: Self.sessionID, audience: Self.audience, issuedAt: Self.now)
        ))
    }

    func testA401AfterTheRenewalIsUnauthorizedAndKeepsTheSession() async {
        installSession()
        let http = ScriptedHTTP([
            .status(401, #"{"error":"unauthorized"}"#),
            .status(200, Self.renewed),
            .status(401, #"{"error":"unauthorized"}"#),
        ])

        await assertMint(throws: .unauthorized, via: http)

        XCTAssertEqual(http.requests.count, 3, "one renewal, one more mint, no loop")
        XCTAssertEqual(store.record?.credential, "2.c2Vjb25k", "the session stays")
    }

    func testA401WhoseRenewalEndsTheSessionReportsWhy() async {
        installSession()
        let http = ScriptedHTTP([
            .status(401, #"{"error":"unauthorized"}"#),
            .status(401, #"{"error":"session_ended","reason":"idle"}"#),
        ])

        await assertMint(throws: .sessionEnded(.idle), via: http)

        XCTAssertEqual(http.requests.count, 2)
    }

    func testA401WhoseRenewalFailsAtIdentityIsAServerFailure() async {
        installSession()
        let before = store.record
        let http = ScriptedHTTP([.status(401, #"{"error":"unauthorized"}"#), .status(503, "")])

        await assertMint(throws: .serverFailure, via: http)

        XCTAssertEqual(store.record, before)
    }

    // MARK: - Refusals never end the session

    func testRefusalsLeaveTheSessionAsItWas() async {
        let cases: [(ScriptedHTTP.Outcome, GameTokenError)] = [
            (.answer(429, #"{"error":"rate_limited"}"#, headers: ["Retry-After": "7"]), .rateLimited(retryAfter: 7)),
            (.status(429, #"{"error":"rate_limited"}"#), .rateLimited(retryAfter: 60)),
            (.status(400, #"{"error":"invalid_audience"}"#), .invalidAudience),
            (.status(400, #"{"error":"invalid_request"}"#), .unexpectedResponse(status: 400)),
            (.status(422, ""), .unexpectedResponse(status: 422)),
            (.status(500, #"{"error":"server_error"}"#), .serverFailure),
            (.status(503, #"{"error":"game_tokens_unavailable"}"#), .unavailable),
            (.status(418, ""), .unexpectedResponse(status: 418)),
            (.status(200, "not json"), .unexpectedResponse(status: 200)),
        ]
        for (outcome, expected) in cases {
            installSession()
            let before = store.record
            let http = ScriptedHTTP([outcome])

            await assertMint(throws: expected, via: http)

            XCTAssertEqual(http.requests.count, 1, "\(expected)")
            XCTAssertEqual(store.record, before, "\(expected) must not touch the session")
        }
    }

    func testALostAnswerIsTheTransportsErrorAndKeepsTheSession() async {
        installSession()
        let before = store.record
        let http = ScriptedHTTP([.failure(URLError(.timedOut))])

        do {
            _ = try await sessions.gameToken(audience: Self.audience, via: endpoint(http))
            XCTFail("expected the URLError")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }

        XCTAssertEqual(store.record, before, "a lost mint answer costs nothing")
    }

    // MARK: - Clock

    func testAWrongClockIsCorrectedFromServerTimeWithoutARenewal() async throws {
        let key = installSession()
        clock.now = Date(timeIntervalSince1970: TimeInterval(Self.now - 1000))
        let http = ScriptedHTTP([
            .status(400, #"{"error":"invalid_issued_at","serverTime":1794268800}"#),
            .status(200, Self.minted),
        ])

        let token = try await sessions.gameToken(audience: Self.audience, via: endpoint(http))

        XCTAssertEqual(http.requests.map(\.url?.path), ["/game/token", "/game/token"], "no renewal for a clock")
        XCTAssertEqual(Self.body(of: http.requests[0])["issuedAt"] as? Int64, Self.now - 1000)
        XCTAssertEqual(Self.body(of: http.requests[1])["issuedAt"] as? Int64, Self.now)
        XCTAssertNil(token.renewedSession)

        // The proof's t is corrected by the same offset.
        let proof = try await sessions.gameRequestProof(
            for: token, method: "GET", url: URL(string: "https://game.example/v1/war")!, body: nil
        )
        XCTAssertEqual(proof.timestamp, Self.now)
        XCTAssertTrue(Self.verifies(proof.signature, by: key.publicKey, over: GameTokenMessage.request(
            audience: Self.audience, method: "GET", target: "/v1/war", t: Self.now, body: Data(), token: token.token
        )))
    }

    /// `expiresAt` is identity's time. An app compares it with its own clock, so a device 20 minutes
    /// ahead would take every new 15-minute token for an expired one and mint before each call.
    func testTheExpiryIsToldOnThisDevicesClock() async throws {
        installSession()
        clock.now = Date(timeIntervalSince1970: TimeInterval(Self.now + 1200))
        let http = ScriptedHTTP([
            .status(400, #"{"error":"invalid_issued_at","serverTime":1794268800}"#),
            .status(200, Self.minted),
        ])

        let token = try await sessions.gameToken(audience: Self.audience, via: endpoint(http))

        XCTAssertEqual(token.expiresAt.timeIntervalSince(clock.now), 900)
    }

    func testAClockRefusedTwiceIsReported() async {
        installSession()
        let before = store.record
        let http = ScriptedHTTP([
            .status(400, #"{"error":"invalid_issued_at","serverTime":1794268800}"#),
            .status(400, #"{"error":"invalid_issued_at","serverTime":1794268800}"#),
        ])

        await assertMint(throws: .clockRejected, via: http)

        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(store.record, before)
    }

    // MARK: - Renewing an old session first

    func testASessionUnusedForHalfItsIdleLimitIsRenewedBeforeTheMint() async throws {
        installSession(renewedAgo: 1980)
        let http = ScriptedHTTP([.status(200, Self.renewed), .status(200, Self.minted)])

        let token = try await sessions.gameToken(audience: Self.audience, via: endpoint(http))

        XCTAssertEqual(http.requests.map(\.url?.path), ["/session/refresh", "/game/token"])
        XCTAssertEqual(token.renewedSession?.token, "renewed-token")
        XCTAssertEqual(store.record?.renewedAt, clock.now)
    }

    func testARecentlyRenewedSessionIsNotRenewedBeforeTheMint() async throws {
        installSession(renewedAgo: 1979)
        let http = ScriptedHTTP([.status(200, Self.minted)])

        _ = try await sessions.gameToken(audience: Self.audience, via: endpoint(http))

        XCTAssertEqual(http.requests.map(\.url?.path), ["/game/token"])
    }

    func testA401AfterAnEarlyRenewalIsNotRenewedAgain() async {
        installSession(renewedAgo: 3000)
        let http = ScriptedHTTP([.status(200, Self.renewed), .status(401, #"{"error":"unauthorized"}"#)])

        await assertMint(throws: .unauthorized, via: http)

        XCTAssertEqual(http.requests.count, 2)
    }

    func testAnEarlyRenewalThatEndsTheSessionReportsWhy() async {
        installSession(renewedAgo: 5000)
        let http = ScriptedHTTP([.status(401, #"{"error":"session_ended","reason":"idle"}"#)])

        await assertMint(throws: .sessionEnded(.idle), via: http)

        XCTAssertEqual(http.requests.count, 1)
    }

    func testAnEarlyRenewalThatFailsAtIdentityStillMints() async throws {
        installSession(renewedAgo: 3000)
        let http = ScriptedHTTP([.status(503, ""), .status(200, Self.minted)])

        let token = try await sessions.gameToken(audience: Self.audience, via: endpoint(http))

        XCTAssertEqual(token.token, "Z2FtZS10b2tlbg")
        XCTAssertNil(token.renewedSession)
    }

    /// A record kept by an earlier release says nothing of its last renewal: no early renewal.
    func testARecordFromBeforeThisReleaseDecodesAndMints() async throws {
        let stored = #"{"sessionId":"0f0e0d0c-0b0a-8908-8706-050403020100","credential":"1.Zmlyc3Q","deviceKey":"AAEC","account":"a"}"#
        let record = try JSONDecoder().decode(PasskeySessionRecord.self, from: Data(stored.utf8))
        XCTAssertNil(record.renewedAt)
        XCTAssertNil(record.idleTimeoutSeconds)

        installSession(renewedAgo: nil)
        let http = ScriptedHTTP([.status(200, Self.minted)])
        _ = try await sessions.gameToken(audience: Self.audience, via: endpoint(http))
        XCTAssertEqual(http.requests.map(\.url?.path), ["/game/token"])
    }

    func testOpeningAndRenewingRecordWhenTheSessionWasLastUsed() async throws {
        let opened =
            #"{"sessionId":"0f0e0d0c-0b0a-8908-8706-050403020100","credential":"1.Zmlyc3Q","sessionExpiresAt":1794355200,"idleTimeoutSeconds":3960}"#
        let http = ScriptedHTTP([.status(201, opened), .status(200, Self.renewed)])

        let didOpen = await sessions.open(token: TestCWT.token(sub: Self.sub, cti: [1, 2, 3]), via: endpoint(http))
        XCTAssertTrue(didOpen)
        XCTAssertEqual(store.record?.renewedAt, clock.now)
        XCTAssertEqual(store.record?.idleTimeoutSeconds, 3960)

        clock.now = clock.now.addingTimeInterval(600)
        _ = try await sessions.renew(via: endpoint(http))
        XCTAssertEqual(store.record?.renewedAt, clock.now)
        XCTAssertEqual(store.record?.idleTimeoutSeconds, 3960)
    }

    // MARK: - Client

    func testTheClientMintsAtItsIdentityAndSignsWithItsSession() async throws {
        let client = makeTestClient()
        client.passkeySessions = sessions
        let key = installSession()
        let http = ScriptedHTTP([.status(200, Self.minted)])
        client.httpData = http.perform

        let token = try await client.gameToken(audience: Self.audience)
        let proof = try await client.gameRequestProof(
            for: token, method: "GET", url: URL(string: "https://game.example/v1/war")!, body: nil
        )

        XCTAssertEqual(http.requests.map(\.url?.absoluteString), ["https://identity.example.test/game/token"])
        XCTAssertEqual(proof.token, token.token)
        XCTAssertTrue(Self.verifies(proof.signature, by: key.publicKey, over: GameTokenMessage.request(
            audience: Self.audience, method: "GET", target: "/v1/war", t: proof.timestamp, body: Data(), token: token.token
        )))
    }

    // MARK: - Request proof

    func testTheProofSignsTheSevenLinesWithTheDeviceKey() async throws {
        let key = installSession()
        let token = GameToken(token: "Z2FtZS10b2tlbg", audience: Self.audience, expiresAt: clock.now, onlinePlay: true)
        let body = Data(#"{"war":7}"#.utf8)

        let proof = try await sessions.gameRequestProof(
            for: token, method: "post", url: URL(string: "https://game.example/v1/runs?war=7")!, body: body
        )

        XCTAssertEqual(proof.token, "Z2FtZS10b2tlbg")
        XCTAssertEqual(proof.timestamp, Self.now)
        XCTAssertTrue(Self.verifies(proof.signature, by: key.publicKey, over: GameTokenMessage.request(
            audience: Self.audience, method: "POST", target: "/v1/runs?war=7", t: Self.now, body: body, token: token.token
        )))
        XCTAssertFalse(proof.signature.contains("="), "unpadded")
    }

    func testAProofWithoutASessionIsNoSession() async {
        await assertProof(throws: .noSession)
    }

    /// A line break in any line would let a caller forge another message's shape.
    func testAProofRefusesWhatWouldAddOrEmptyALine() async {
        installSession()
        await assertProof(throws: .invalidRequest, method: "GET\nX")
        await assertProof(throws: .invalidRequest, method: "")
        await assertProof(throws: .invalidRequest, method: "GET /")
        await assertProof(throws: .invalidRequest, audience: "https://game.example\nPOST")
        await assertProof(throws: .invalidRequest, audience: "")
    }

    /// This is a game: a Secure Enclave signature must not hold the main thread.
    func testTheProofIsSignedOffTheMainThread() async throws {
        let key = ThreadRecordingKey()
        sessions = PasskeySessions(store: store, keys: OneSessionKey(key), now: clock.read)
        installSession()
        let token = GameToken(token: "abc", audience: Self.audience, expiresAt: clock.now, onlinePlay: false)

        _ = try await sessions.gameRequestProof(
            for: token, method: "GET", url: URL(string: "https://game.example/v1/war")!, body: nil
        )

        XCTAssertEqual(key.signedOnMainThread, [false])
    }
}

/// A clock a test sets.
@MainActor
final class TestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    func read() -> Date { now }
}

/// A software device key that notes which thread each signature ran on.
final class ThreadRecordingKey: SessionDeviceKey, @unchecked Sendable {
    private let key = P256.Signing.PrivateKey()
    private let lock = NSLock()
    private var onMain: [Bool] = []

    var signedOnMainThread: [Bool] { lock.withLock { onMain } }
    var publicKey: Data { key.publicKey.x963Representation }
    var persistentForm: Data { key.rawRepresentation }

    func signature(for message: Data) throws -> Data {
        lock.withLock { onMain.append(Thread.isMainThread) }
        return try key.signature(for: message).rawRepresentation
    }
}

/// Always hands back the one key it was given.
@MainActor
final class OneSessionKey: SessionKeyFactory {
    private let key: any SessionDeviceKey

    init(_ key: any SessionDeviceKey) {
        self.key = key
    }

    func make() throws -> any SessionDeviceKey { key }
    func restore(_: Data) throws -> any SessionDeviceKey { key }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var b64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        self.init(base64Encoded: b64)
    }
}
