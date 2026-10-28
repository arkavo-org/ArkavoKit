import CryptoKit
import XCTest
@testable import ArkavoSocial

/// Passkey session renewal (authnz-rs #108, `docs/session-renewal.md`): the
/// byte-exact messages and encodings, and how each identity answer to an open,
/// a renewal and a sign-out changes what this app keeps.
@MainActor
final class PasskeySessionTests: XCTestCase {
    private static let identity = URL(string: "https://identity.example.test")!
    /// The server's own vectors (authnz-rs `session_tests.rs`, `messages_and_session_id_are_byte_exact`).
    private static let sub = "0a1b2c3d-0000-4000-8000-000000000001"
    private static let sessionID = "0f0e0d0c-0b0a-8908-8706-050403020100"
    /// A token of `sub` whose `cti` is the bytes 1, 2, 3 ("AQID").
    private static let token = TestCWT.token(sub: sub, cti: [1, 2, 3])
    private static let opened =
        #"{"sessionId":"0f0e0d0c-0b0a-8908-8706-050403020100","credential":"1.Zmlyc3Q","sessionExpiresAt":1790086400,"idleTimeoutSeconds":3960}"#
    private static let renewed =
        #"{"token":"renewed-token","expiresAt":1790003600,"credential":"2.c2Vjb25k","sessionExpiresAt":1790086400}"#

    private var store: InMemorySessionStore!
    private var keys: SoftwareSessionKeys!
    private var sessions: PasskeySessions!

    override func setUp() async throws {
        store = InMemorySessionStore()
        keys = SoftwareSessionKeys()
        sessions = PasskeySessions(store: store, keys: keys)
    }

    private func endpoint(_ http: ScriptedHTTP) -> PasskeySessionEndpoint {
        PasskeySessionEndpoint(identity: Self.identity, send: http.perform)
    }

    /// A stored session at generation 1, with a fresh software device key.
    @discardableResult
    private func installSession(account: String = PasskeySessionTests.sub) -> P256.Signing.PrivateKey {
        let key = P256.Signing.PrivateKey()
        store.record = PasskeySessionRecord(
            sessionId: Self.sessionID,
            credential: "1.Zmlyc3Q",
            deviceKey: key.rawRepresentation,
            account: account
        )
        return key
    }

    private static func body(of request: URLRequest) -> [String: String] {
        guard let data = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
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

    private func assertRenewal(
        throws expected: PasskeySessionError,
        via http: ScriptedHTTP,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await sessions.renew(via: endpoint(http))
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as PasskeySessionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Messages and encodings

    func testMessagesAreTheServersVectors() {
        XCTAssertEqual(
            PasskeySessionMessage.open(sub: Self.sub, cti: Data([1, 2, 3]), publicKey: "BKEY"),
            "arkavo-session-open-v1\n0a1b2c3d-0000-4000-8000-000000000001\nAQID\nBKEY"
        )
        XCTAssertEqual(
            PasskeySessionMessage.refresh(sessionId: Self.sessionID, credential: "7.c2VjcmV0"),
            "arkavo-session-refresh-v1\n0f0e0d0c-0b0a-8908-8706-050403020100\n7.c2VjcmV0"
        )
        XCTAssertEqual(
            PasskeySessionMessage.signout(sessionId: Self.sessionID),
            "arkavo-session-signout-v1\n0f0e0d0c-0b0a-8908-8706-050403020100"
        )
    }

    /// A key and signature made by OpenSSL, not CryptoKit: the X9.63 point is
    /// `04||x||y`, and the contract's raw `r||s` is the order CryptoKit reads.
    /// Both r and s have the high bit set, so their DER form is 33 bytes each.
    func testEncodingsMatchAnIndependentSigner() throws {
        let scalar = Data(hex: "f941c31b80bb68033c5250ca6afc44356ce8246205195446fb77563706629d59")
        let publicKey = "BHsLx1y_qXdrTt3hTzD1PWnv0p-2EwaKHsVQDB25u7DxhNi2FmlbYJef_Ke-7rpocHA2ZJK9UWO3m-xez8y3d34"
        let signature = "ytb8xCI43KGRsk-nMWo-T8DezodYtkZ0RdwLD-bzdmLdtv-YYGpdBdH1lDpvNsDkD3UKTwUdVHLO0h1DpMNRTg"
        let message = PasskeySessionMessage.open(sub: Self.sub, cti: Data([1, 2, 3]), publicKey: "BKEY")

        let key = SoftwareSessionKey(key: try P256.Signing.PrivateKey(rawRepresentation: scalar))
        XCTAssertEqual(key.publicKey.count, 65)
        XCTAssertEqual(key.publicKey.base64URLEncodedString(), publicKey)

        let verifier = try P256.Signing.PublicKey(x963Representation: XCTUnwrap(Data(base64URLEncoded: publicKey)))
        XCTAssertTrue(Self.verifies(signature, by: verifier, over: message))
        // And what the device key signs is raw r||s too.
        let ours = try key.signature(for: Data(message.utf8))
        XCTAssertTrue(Self.verifies(ours.base64URLEncodedString(), by: verifier, over: message))
    }

    /// The Secure Enclave key signs raw r||s and exports only its public X9.63 point.
    func testSecureEnclaveKeySignsRawSignatures() throws {
        try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave on this machine")
        let made = try SecureEnclaveSessionKeys().make()
        let restored = try SecureEnclaveSessionKeys().restore(made.persistentForm)
        XCTAssertEqual(restored.publicKey, made.publicKey)
        XCTAssertEqual(made.publicKey.count, 65)
        XCTAssertEqual(made.publicKey.first, 0x04)

        let verifier = try P256.Signing.PublicKey(x963Representation: made.publicKey)
        let signature = try restored.signature(for: Data("m".utf8))
        XCTAssertTrue(Self.verifies(signature.base64URLEncodedString(), by: verifier, over: "m"))
    }

    func testTokenClaimsNameTheSubjectAndTheTokenID() throws {
        let claims = try XCTUnwrap(CWTSubject.subjectAndID(fromToken: Self.token))
        XCTAssertEqual(claims.sub, Self.sub)
        XCTAssertEqual(claims.cti, Data([1, 2, 3]))
        XCTAssertNil(CWTSubject.subjectAndID(fromToken: TestCWT.token(sub: Self.sub)), "no cti")
    }

    // MARK: - Open

    func testOpenSendsTheTokenAndAProofAndKeepsTheSession() async throws {
        let http = ScriptedHTTP([.status(201, Self.opened)])

        let opened = await sessions.open(token: Self.token, via: endpoint(http))

        XCTAssertTrue(opened)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://identity.example.test/session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Token"), Self.token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = Self.body(of: request)
        let publicKey = try XCTUnwrap(body["publicKey"])
        let deviceKey = try XCTUnwrap(keys.made.first)
        XCTAssertEqual(publicKey, deviceKey.publicKey.x963Representation.base64URLEncodedString())
        XCTAssertTrue(Self.verifies(
            body["proof"],
            by: deviceKey.publicKey,
            over: PasskeySessionMessage.open(sub: Self.sub, cti: Data([1, 2, 3]), publicKey: publicKey)
        ))

        XCTAssertEqual(store.record, PasskeySessionRecord(
            sessionId: Self.sessionID,
            credential: "1.Zmlyc3Q",
            deviceKey: deviceKey.rawRepresentation,
            account: Self.sub
        ))
    }

    func testARefusedOpenKeepsNoSession() async {
        let http = ScriptedHTTP([.status(401, #"{"error":"passkey_assertion_required"}"#)])

        let opened = await sessions.open(token: Self.token, via: endpoint(http))

        XCTAssertFalse(opened)
        XCTAssertNil(store.record)
    }

    func testAnOpenWhoseAnswerIsLostKeepsNoSession() async {
        let http = ScriptedHTTP([.failure(URLError(.timedOut))])

        let opened = await sessions.open(token: Self.token, via: endpoint(http))

        XCTAssertFalse(opened)
        XCTAssertNil(store.record)
    }

    func testATokenWithoutAnIDOpensNothing() async {
        let http = ScriptedHTTP([.status(201, Self.opened)])

        let opened = await sessions.open(token: TestCWT.token(sub: Self.sub), via: endpoint(http))

        XCTAssertFalse(opened)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNil(store.record)
    }

    /// A token the session cannot be opened with leaves the session this app held.
    func testATokenWithoutAnIDKeepsThePreviousSession() async {
        installSession()
        let before = store.record
        let http = ScriptedHTTP([.status(204, "")])

        let opened = await sessions.open(token: TestCWT.token(sub: Self.sub), via: endpoint(http))

        XCTAssertFalse(opened)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(store.record, before)
    }

    func testASessionIDThatIsNoUUIDIsNotKept() async {
        let reply = #"{"sessionId":"nope","credential":"1.Zmlyc3Q","sessionExpiresAt":1,"idleTimeoutSeconds":1}"#
        let http = ScriptedHTTP([.status(201, reply)])

        let opened = await sessions.open(token: Self.token, via: endpoint(http))

        XCTAssertFalse(opened)
        XCTAssertNil(store.record)
    }

    func testWithoutASecureEnclaveKeyNothingIsSent() async {
        keys.failsToMake = true
        let http = ScriptedHTTP([.status(201, Self.opened)])

        let opened = await sessions.open(token: Self.token, via: endpoint(http))

        XCTAssertFalse(opened)
        XCTAssertTrue(http.requests.isEmpty)
    }

    /// A new sign-in supersedes the session this app held: it is signed out first.
    func testOpeningSignsOutThePreviousSession() async throws {
        let previous = installSession(account: "another")
        let http = ScriptedHTTP([.status(204, ""), .status(201, Self.opened)])

        let opened = await sessions.open(token: Self.token, via: endpoint(http))

        XCTAssertTrue(opened)
        XCTAssertEqual(http.requests.map(\.url?.path), ["/session/signout", "/session"])
        XCTAssertTrue(Self.verifies(
            Self.body(of: http.requests[0])["signature"],
            by: previous.publicKey,
            over: PasskeySessionMessage.signout(sessionId: Self.sessionID)
        ))
        XCTAssertEqual(store.record?.account, Self.sub)
    }

    // MARK: - Renew

    func testRenewalWithoutASessionSendsNothing() async {
        let http = ScriptedHTTP([.status(200, Self.renewed)])

        await assertRenewal(throws: .noSession, via: http)

        XCTAssertTrue(http.requests.isEmpty)
    }

    func testRenewalSignsTheCredentialReturnsTheTokenAndKeepsTheNextCredential() async throws {
        let key = installSession()
        let http = ScriptedHTTP([.status(200, Self.renewed)])

        let renewed = try await sessions.renew(via: endpoint(http))

        XCTAssertEqual(renewed, RenewedSession(
            token: "renewed-token",
            expiresAt: Date(timeIntervalSince1970: 1_790_003_600),
            sessionExpiresAt: Date(timeIntervalSince1970: 1_790_086_400)
        ))
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://identity.example.test/session/refresh")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Auth-Token"), "renewal sends no token")
        let body = Self.body(of: request)
        XCTAssertEqual(body["sessionId"], Self.sessionID)
        XCTAssertEqual(body["credential"], "1.Zmlyc3Q")
        XCTAssertTrue(Self.verifies(
            body["signature"],
            by: key.publicKey,
            over: PasskeySessionMessage.refresh(sessionId: Self.sessionID, credential: "1.Zmlyc3Q")
        ))
        XCTAssertEqual(store.record?.credential, "2.c2Vjb25k")
        XCTAssertEqual(store.record?.sessionId, Self.sessionID)
    }

    /// The server has already spent the old credential, so a store that fails
    /// leaves no session to present it again; the token is still returned.
    func testRenewalWhoseCredentialCannotBeKeptForgetsTheSession() async throws {
        installSession()
        store.saveError = KeychainManager.KeychainError.unknown(-25308)
        let http = ScriptedHTTP([.status(200, Self.renewed)])

        let renewed = try await sessions.renew(via: endpoint(http))

        XCTAssertEqual(renewed.token, "renewed-token")
        XCTAssertNil(store.record)
    }

    func testEveryEndedReasonEndsTheSession() async {
        let reasons: [(String, SessionEndReason)] = [
            ("not_found", .notFound), ("invalid_proof", .invalidProof), ("invalid_credential", .invalidCredential),
            ("reused", .reused), ("idle", .idle), ("expired", .expired), ("account_deleted", .accountDeleted),
            ("something_new", .unexpectedResponse),
        ]
        for (wire, reason) in reasons {
            installSession()
            let http = ScriptedHTTP([.status(401, #"{"error":"session_ended","reason":"\#(wire)"}"#)])

            await assertRenewal(throws: .sessionEnded(reason), via: http)

            XCTAssertNil(store.record, wire)
        }
    }

    func testAServerFailureKeepsTheSessionAndItsCredential() async {
        for status in [500, 503] {
            installSession()
            let before = store.record
            let http = ScriptedHTTP([.status(status, #"{"error":"server_error"}"#)])

            await assertRenewal(throws: .serverFailure, via: http)

            XCTAssertEqual(store.record, before, "\(status)")
        }
    }

    /// The contract: a response lost in transit may have rotated the
    /// credential, so presenting it again would end the session as reused.
    func testALostAnswerEndsTheSession() async {
        installSession()
        let http = ScriptedHTTP([.failure(URLError(.timedOut))])

        await assertRenewal(throws: .sessionEnded(.responseLost), via: http)

        XCTAssertNil(store.record)
    }

    /// No request left the device, so the credential is unspent.
    func testAnErrorBeforeSendingKeepsTheSession() async {
        for code in [URLError.Code.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed] {
            installSession()
            let before = store.record
            let http = ScriptedHTTP([.failure(URLError(code))])

            do {
                _ = try await sessions.renew(via: endpoint(http))
                XCTFail("expected the URLError")
            } catch let error as URLError {
                XCTAssertEqual(error.code, code)
            } catch {
                XCTFail("expected the URLError, got \(error)")
            }
            XCTAssertEqual(store.record, before, "\(code)")
        }
    }

    func testAnUnreadableAnswerEndsTheSession() async {
        for outcome in [ScriptedHTTP.Outcome.status(200, "{}"), .status(404, ""), .status(401, "")] {
            installSession()
            let http = ScriptedHTTP([outcome])

            await assertRenewal(throws: .sessionEnded(.unexpectedResponse), via: http)

            XCTAssertNil(store.record)
        }
    }

    /// A device key that no longer loads cannot renew or sign out.
    func testAnUnusableDeviceKeyIsNoSession() async {
        installSession()
        store.record?.deviceKey = Data([1, 2, 3])
        let http = ScriptedHTTP([.status(200, Self.renewed)])

        await assertRenewal(throws: .noSession, via: http)

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNil(store.record)
    }

    /// Two renewals with one credential would end the session as reused.
    func testConcurrentRenewalsShareOneRequest() async throws {
        installSession()
        let http = GatedHTTP(answer: (200, Self.renewed))
        let endpoint = PasskeySessionEndpoint(identity: Self.identity, send: http.perform)
        let sessions = sessions!

        async let first = sessions.renew(via: endpoint)
        async let second = sessions.renew(via: endpoint)
        await http.gate.waitUntilHolding()
        http.gate.open()
        let (a, b) = try await (first, second)

        XCTAssertEqual(a, b)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(store.record?.credential, "2.c2Vjb25k")
    }

    /// A renewal after the first one finished sends the next credential.
    func testSequentialRenewalsRotateTheCredential() async throws {
        installSession()
        let next = #"{"token":"t3","expiresAt":1,"credential":"3.dGhpcmQ","sessionExpiresAt":2}"#
        let http = ScriptedHTTP([.status(200, Self.renewed), .status(200, next)])

        _ = try await sessions.renew(via: endpoint(http))
        _ = try await sessions.renew(via: endpoint(http))

        XCTAssertEqual(http.requests.map { Self.body(of: $0)["credential"] }, ["1.Zmlyc3Q", "2.c2Vjb25k"])
        XCTAssertEqual(store.record?.credential, "3.dGhpcmQ")
    }

    // MARK: - End

    func testEndSignsOutAndForgetsTheSession() async throws {
        let key = installSession()
        let http = ScriptedHTTP([.status(204, "")])

        await sessions.end(via: endpoint(http))

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://identity.example.test/session/signout")
        let body = Self.body(of: request)
        XCTAssertEqual(body["sessionId"], Self.sessionID)
        XCTAssertTrue(Self.verifies(
            body["signature"],
            by: key.publicKey,
            over: PasskeySessionMessage.signout(sessionId: Self.sessionID)
        ))
        XCTAssertNil(store.record)
    }

    func testEndForgetsTheSessionWhateverTheAnswer() async {
        let outcomes: [ScriptedHTTP.Outcome] = [
            .status(401, #"{"error":"session_ended","reason":"invalid_proof"}"#),
            .status(500, ""),
            .failure(URLError(.notConnectedToInternet)),
        ]
        for outcome in outcomes {
            installSession()
            await sessions.end(via: endpoint(ScriptedHTTP([outcome])))
            XCTAssertNil(store.record)
        }
    }

    func testEndWithoutASessionSendsNothing() async {
        let http = ScriptedHTTP([.status(204, "")])

        await sessions.end(via: endpoint(http))

        XCTAssertTrue(http.requests.isEmpty)
    }

    /// A sign-out during a renewal waits for it, so the renewal cannot store a
    /// credential after the session was forgotten.
    func testEndWaitsForARenewalInFlight() async throws {
        installSession()
        let http = GatedHTTP(answer: (200, Self.renewed))
        let endpoint = PasskeySessionEndpoint(identity: Self.identity, send: http.perform)
        let sessions = sessions!

        async let renewal = sessions.renew(via: endpoint)
        await http.gate.waitUntilHolding()
        async let ended: Void = sessions.end(via: endpoint)
        await Task.yield()
        XCTAssertEqual(http.requests.count, 1, "the sign-out waits")
        http.gate.open()
        _ = try await renewal
        await http.gate.waitUntilHolding()
        http.gate.open()
        await ended

        XCTAssertEqual(http.requests.map(\.url?.path), ["/session/refresh", "/session/signout"])
        XCTAssertNil(store.record)
    }

    // MARK: - Account deletion

    func testDiscardForgetsOnlyThatAccountsSession() async {
        installSession(account: Self.sub)
        await sessions.discard(account: UUID(uuidString: "9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")!)
        XCTAssertNotNil(store.record)

        await sessions.discard(account: UUID(uuidString: Self.sub)!)
        XCTAssertNil(store.record)
    }

    // MARK: - ArkavoClient

    func testTheClientRenewsAndEndsAtItsIdentity() async throws {
        let client = makeTestClient()
        client.passkeySessions = sessions
        installSession()
        let http = ScriptedHTTP([.status(200, Self.renewed), .status(204, "")])
        client.httpData = http.perform

        let renewed = try await client.renewSession()
        await client.endSession()

        XCTAssertEqual(renewed.token, "renewed-token")
        XCTAssertEqual(http.requests.map(\.url?.absoluteString), [
            "https://identity.example.test/session/refresh",
            "https://identity.example.test/session/signout",
        ])
        XCTAssertNil(store.record)
    }

    func testDeletingTheAccountForgetsItsSession() async throws {
        let harness = DeletionHarness()
        harness.client.passkeySessions = sessions
        installSession(account: DeletionHarness.account.uuidString.lowercased())
        harness.stubCeremonies([.success(DeletionHarness.token(of: DeletionHarness.account))])
        harness.stubHTTP([.status(202, "{}")])

        _ = try await harness.client.deleteAccount(accountName: "alice")

        XCTAssertNil(store.record)
    }
}

// MARK: - Doubles

/// A Secure Enclave device key, in software.
struct SoftwareSessionKey: SessionDeviceKey {
    let key: P256.Signing.PrivateKey

    var publicKey: Data { key.publicKey.x963Representation }
    var persistentForm: Data { key.rawRepresentation }

    func signature(for message: Data) throws -> Data {
        try key.signature(for: message).rawRepresentation
    }
}

/// Makes software keys and remembers each one.
@MainActor
final class SoftwareSessionKeys: SessionKeyFactory {
    var failsToMake = false
    private(set) var made: [P256.Signing.PrivateKey] = []

    func make() throws -> any SessionDeviceKey {
        if failsToMake { throw CryptoKitError.underlyingCoreCryptoError(error: -1) }
        let key = P256.Signing.PrivateKey()
        made.append(key)
        return SoftwareSessionKey(key: key)
    }

    func restore(_ persistentForm: Data) throws -> any SessionDeviceKey {
        SoftwareSessionKey(key: try P256.Signing.PrivateKey(rawRepresentation: persistentForm))
    }
}

@MainActor
final class InMemorySessionStore: PasskeySessionStore {
    var record: PasskeySessionRecord?
    var saveError: Error?

    func load() -> PasskeySessionRecord? { record }

    func save(_ record: PasskeySessionRecord) throws {
        if let saveError { throw saveError }
        self.record = record
    }

    func delete() { record = nil }
}

/// Answers every request with one status and body, each held at `gate` until the test opens it.
@MainActor
final class GatedHTTP {
    let gate = Gate()
    private let answer: (Int, String)
    private(set) var requests: [URLRequest] = []

    init(answer: (Int, String)) {
        self.answer = answer
    }

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        await gate.pass()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(answer.1.utf8), response)
    }
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    init?(base64URLEncoded string: String) {
        var b64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        self.init(base64Encoded: b64)
    }
}
