import Synchronization
import XCTest
@testable import ArkavoSocial

/// The stored session as Google's answers move it: sign-in, refresh, sign-out, and a grant
/// withdrawn at Google, including answers that arrive after the session they were asked for.
@MainActor
final class YouTubeSessionTests: XCTestCase {
    private nonisolated static let invalidGrant = #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
    private static let redirectUri = "http://127.0.0.1:8080/callback"

    private nonisolated static func tokens(access: String, refresh: String? = nil) -> String {
        let refreshField = refresh.map { #","refresh_token":"\#($0)""# } ?? ""
        return #"{"access_token":"\#(access)","expires_in":3600,"scope":"s","token_type":"Bearer"\#(refreshField)}"#
    }

    private nonisolated static func stream(key: String) -> String {
        #"{"id":"s1","snippet":{"title":"t"},"cdn":{"ingestionInfo":{"streamName":"\#(key)","ingestionAddress":"rtmp://x"}}}"#
    }

    private func signIn(_ store: MemorySessionStore, access: String = "a1", refresh: String = "r1") {
        store.save(access, for: "access_token")
        store.save(refresh, for: "refresh_token")
        store.save(ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)), for: "token_expiration")
    }

    private func client(_ store: MemorySessionStore, _ google: FakeGoogle) -> YouTubeClient {
        YouTubeClient(clientId: "client", clientSecret: "secret", store: store, send: google.send)
    }

    // MARK: Answers for a session that has since ended

    /// Sign-out revokes the very refresh token a running refresh sent, so Google answers that
    /// refresh `invalid_grant`. The person signed out; nothing was withdrawn.
    func testInvalidGrantForARefreshSentBeforeSignOutWithdrawsNothing() async {
        let store = MemorySessionStore()
        signIn(store)
        let held = HeldRefresh()
        let google = FakeGoogle { request, _ in
            if request.isRefresh { return await held.answer() }
            if request.isRevoke { return (200, "") }
            return unexpected(request)
        }
        let client = client(store, google)

        async let verified = client.verifyAccess()
        await held.arrival()
        await client.signOut()
        held.reply(400, Self.invalidGrant)

        let stillStands = await verified
        XCTAssertTrue(stillStands)
        XCTAssertFalse(client.accessWithdrawn)
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertTrue(store.isEmpty)
    }

    /// A refresh Google grants after sign-out must not store the ended session again.
    func testARefreshGrantedAfterSignOutStoresNothing() async {
        let store = MemorySessionStore()
        signIn(store)
        let held = HeldRefresh()
        let google = FakeGoogle { request, _ in
            if request.isRefresh { return await held.answer() }
            if request.isRevoke { return (200, "") }
            return unexpected(request)
        }
        let client = client(store, google)

        async let verified = client.verifyAccess()
        await held.arrival()
        await client.signOut()
        held.reply(200, Self.tokens(access: "a2"))

        _ = await verified
        XCTAssertTrue(store.isEmpty, "the ended session was stored again: \(store.contents)")
    }

    /// The person signed out and in again while the old refresh was out. Its answer, whatever
    /// it is, must leave the new session as it is.
    func testAnAnswerForTheOldSessionLeavesANewSignInAlone() async {
        for (status, body) in [(400, Self.invalidGrant), (200, Self.tokens(access: "a2"))] {
            let store = MemorySessionStore()
            signIn(store)
            let held = HeldRefresh()
            let google = FakeGoogle { request, _ in
                if request.isRefresh { return await held.answer() }
                if request.isRevoke { return (200, "") }
                return unexpected(request)
            }
            let client = client(store, google)

            async let verified = client.verifyAccess()
            await held.arrival()
            await client.signOut()
            signIn(store, access: "a9", refresh: "r9")
            held.reply(status, body)

            _ = await verified
            XCTAssertFalse(client.accessWithdrawn, "answer \(status)")
            XCTAssertEqual(store.value(for: "access_token"), "a9", "answer \(status)")
            XCTAssertEqual(store.value(for: "refresh_token"), "r9", "answer \(status)")
        }
    }

    // MARK: Sign-in

    /// The channel fetch that ends sign-in can find the grant already gone. That verdict is
    /// the state left behind, not "signed in" with nothing stored.
    func testASignInWhoseChannelFetchFindsTheGrantGoneEndsWithdrawn() async throws {
        let store = MemorySessionStore()
        let google = FakeGoogle { request, _ in
            if request.isCodeExchange { return (200, Self.tokens(access: "a1", refresh: "r1")) }
            if request.isChannels { return (401, "") }
            if request.isRefresh { return (400, Self.invalidGrant) }
            return unexpected(request)
        }
        let client = client(store, google)

        try await client.completeSignIn(code: "code", redirectUri: Self.redirectUri)

        XCTAssertFalse(client.isAuthenticated)
        XCTAssertTrue(client.accessWithdrawn)
        XCTAssertTrue(store.isEmpty)
    }

    // MARK: A refused access token

    /// A refusal followed by a check that cannot reach Google says nothing about the grant:
    /// the refusal is the error, and the session stays.
    func testAGrantCheckThatFailsLeavesTheRefusalAsTheError() async {
        let store = MemorySessionStore()
        signIn(store)
        let google = FakeGoogle { request, _ in
            if request.isChannels { return (401, "") }
            if request.isRefresh { throw URLError(.notConnectedToInternet) }
            return unexpected(request)
        }
        let client = client(store, google)

        await client.fetchChannelInfo()

        guard case .httpError(statusCode: 401)? = client.error else {
            return XCTFail("expected the 401, got \(String(describing: client.error))")
        }
        XCTAssertFalse(client.accessWithdrawn)
        XCTAssertEqual(store.value(for: "refresh_token"), "r1")
    }

    /// A sign-in Google answered without a refresh token stores an empty one. A refused token
    /// then has nothing to check the grant with, and nothing is sent to Google.
    func testAnEmptyRefreshTokenIsNeverSentToGoogle() async {
        let store = MemorySessionStore()
        signIn(store, refresh: "")
        let google = FakeGoogle { request, _ in
            if request.isChannels { return (401, "") }
            return unexpected(request)
        }
        let client = client(store, google)

        await client.fetchChannelInfo()

        guard case .httpError(statusCode: 401)? = client.error else {
            return XCTFail("expected the 401, got \(String(describing: client.error))")
        }
        XCTAssertEqual(google.requests.filter(\.isRefresh).count, 0)
    }

    /// Any authorized call, not only the channel fetch, notices a grant withdrawn at Google.
    func testAStreamKeyRequestRefusedForAWithdrawnGrantEndsTheSession() async {
        let store = MemorySessionStore()
        signIn(store)
        let google = FakeGoogle { request, _ in
            if request.isLiveStreams { return (401, "") }
            if request.isRefresh { return (400, Self.invalidGrant) }
            return unexpected(request)
        }
        let client = client(store, google)

        do {
            _ = try await client.fetchStreamKey()
            XCTFail("expected accessWithdrawn")
        } catch YouTubeError.accessWithdrawn {
        } catch {
            XCTFail("expected accessWithdrawn, got \(error)")
        }
        XCTAssertTrue(client.accessWithdrawn)
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertTrue(store.isEmpty)
    }

    /// A refused token on a grant that still stands is refreshed, and the request is sent
    /// again as it was, with the new token.
    func testARefusedRequestIsResentOnceWithTheRefreshedToken() async throws {
        let store = MemorySessionStore()
        signIn(store)
        let google = FakeGoogle { request, earlier in
            if request.isLiveStreams, request.httpMethod == "GET" { return (200, #"{"items":[]}"#) }
            if request.isLiveStreams, request.httpMethod == "POST" {
                let earlierPosts = earlier.filter { $0.isLiveStreams && $0.httpMethod == "POST" }
                return earlierPosts.isEmpty ? (401, "") : (200, Self.stream(key: "key-1"))
            }
            if request.isRefresh { return (200, Self.tokens(access: "a2")) }
            return unexpected(request)
        }
        let client = client(store, google)

        let key = try await client.fetchStreamKey()

        XCTAssertEqual(key, "key-1")
        let posts = google.requests.filter { $0.isLiveStreams && $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.map(\.bearer), ["Bearer a1", "Bearer a2"])
        XCTAssertNotNil(posts.first?.httpBody)
        XCTAssertEqual(posts.first?.httpBody, posts.last?.httpBody)
        XCTAssertEqual(store.value(for: "access_token"), "a2")
    }

    /// The new token refused too: the request is not sent a third time.
    func testARequestRefusedAgainAfterARefreshIsNotSentAThirdTime() async {
        let store = MemorySessionStore()
        signIn(store)
        let google = FakeGoogle { request, _ in
            if request.isLiveStreams { return (401, "") }
            if request.isRefresh { return (200, Self.tokens(access: "a2")) }
            return unexpected(request)
        }
        let client = client(store, google)

        do {
            _ = try await client.fetchStreamKey()
            XCTFail("expected the 401")
        } catch YouTubeError.httpError(statusCode: 401) {
        } catch {
            XCTFail("expected the 401, got \(error)")
        }
        XCTAssertEqual(google.requests.filter(\.isLiveStreams).count, 2)
        XCTAssertEqual(google.requests.filter(\.isRefresh).count, 1)
        XCTAssertFalse(client.accessWithdrawn)
    }
}

// MARK: - Test doubles

/// The session store in memory.
final class MemorySessionStore: YouTubeSessionStore {
    private let values = Mutex<[String: String]>([:])

    func value(for account: String) -> String? { values.withLock { $0[account] } }
    func save(_ value: String, for account: String) { values.withLock { $0[account] = value } }
    func delete(_ account: String) { values.withLock { $0[account] = nil } }

    var contents: [String: String] { values.withLock { $0 } }
    var isEmpty: Bool { contents.isEmpty }
}

/// Google as a test scripts it. `respond` gets each request and every request before it.
final class FakeGoogle: Sendable {
    typealias Respond = @Sendable (URLRequest, [URLRequest]) async throws -> (Int, String)

    private let log = Mutex<[URLRequest]>([])
    private let respond: Respond

    init(_ respond: @escaping Respond) {
        self.respond = respond
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    var send: YouTubeSend {
        { [self] request in
            let earlier = log.withLock { log in
                defer { log.append(request) }
                return log
            }
            let (status, body) = try await respond(request, earlier)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}

/// A token refresh held at Google until the test answers it.
final class HeldRefresh: Sendable {
    private let arrivals: AsyncStream<Void>
    private let arrived: AsyncStream<Void>.Continuation
    private let answers: AsyncStream<(Int, String)>
    private let answered: AsyncStream<(Int, String)>.Continuation

    init() {
        (arrivals, arrived) = AsyncStream.makeStream(of: Void.self)
        (answers, answered) = AsyncStream.makeStream(of: (Int, String).self)
    }

    /// Called by the fake: reports the refresh in flight, then waits for the test's answer.
    func answer() async -> (Int, String) {
        arrived.yield()
        for await reply in answers { return reply }
        return (599, "")
    }

    /// Waits until the refresh reaches Google.
    func arrival() async {
        for await _ in arrivals { return }
    }

    func reply(_ status: Int, _ body: String) {
        answered.yield((status, body))
    }
}

private func unexpected(_ request: URLRequest) -> (Int, String) {
    XCTFail("unexpected request: \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")")
    return (500, "")
}

private extension URLRequest {
    var form: String { httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    var isRefresh: Bool { url?.path == "/token" && form.contains("grant_type=refresh_token") }
    var isCodeExchange: Bool { url?.path == "/token" && form.contains("grant_type=authorization_code") }
    var isRevoke: Bool { url?.path == "/revoke" }
    var isChannels: Bool { url?.path == "/youtube/v3/channels" }
    var isLiveStreams: Bool { url?.path == "/youtube/v3/liveStreams" }
    var bearer: String? { value(forHTTPHeaderField: "Authorization") }
}
