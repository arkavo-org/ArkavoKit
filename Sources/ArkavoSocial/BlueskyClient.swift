#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Foundation

// MARK: - Bluesky Client

public actor BlueskyClient: ObservableObject {
    private let httpClient: HTTPClient
    private let baseURL: URL
    @MainActor @Published public private(set) var profile: ProfileViewResponse?
    @MainActor @Published public private(set) var timeline: TimelineResponse?
    @MainActor @Published public var isAuthenticated = false
    @MainActor @Published public var isLoading = false
    @MainActor @Published public var error: Error?

    public init() {
        baseURL = URL(string: "https://bsky.social")!
        httpClient = URLSessionHTTPClient()
        Task { @MainActor in
            checkExistingAuth()
        }
    }

    @MainActor
    public func login(identifier: String, password: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let response = try await createSession(
                identifier: identifier,
                password: password,
            )
            print("Logged in as: \(response.handle)")
        } catch {
            self.error = BlueskyError(error: "Failed to login", message: error.localizedDescription)
        }
    }

    private func createSession(identifier: String, password: String) async throws -> CreateSessionResponse {
        let endpoint = baseURL.appendingPathComponent("/xrpc/com.atproto.server.createSession")
        let request = CreateSessionRequest(identifier: identifier, password: password)

        let response: CreateSessionResponse = try await httpClient.sendRequest(
            endpoint,
            method: "POST",
            body: request,
            headers: [:],
        )
        try KeychainManager.saveBlueskyHandle(response.handle)
        try KeychainManager.saveBlueskyDID(response.did)
        try KeychainManager.saveBlueskyTokens(accessToken: response.accessJwt, refreshToken: response.refreshJwt)
        await checkExistingAuth()
        return response
    }

    private func authenticatedRequest<T: Decodable & Sendable>(
        endpoint: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: (any Encodable & Sendable)? = nil,
        retryCount: Int = 1
    ) async throws -> T {
        guard let accessToken = KeychainManager.getBlueskyAccessToken() else {
            throw BlueskyError(error: "auth_required", message: "No access token available")
        }

        var components = URLComponents(url: baseURL.appendingPathComponent("/xrpc/\(endpoint)"), resolvingAgainstBaseURL: true)
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw BlueskyError(error: "invalid_url", message: "Could not construct valid URL")
        }

        do {
            return try await httpClient.sendRequest(
                url,
                method: method,
                body: method == "GET" ? nil : body,
                headers: ["Authorization": "Bearer \(accessToken)"],
            )
        } catch let error as BlueskyError where error.error == "ExpiredToken" && retryCount > 0 {
            // Token expired, try to refresh and retry the request once
            let _ = try await refreshSession()
            return try await authenticatedRequest(
                endpoint: endpoint,
                method: method,
                queryItems: queryItems,
                body: body,
                retryCount: retryCount - 1,
            )
        } catch {
            throw error
        }
    }

    @MainActor
    private func checkExistingAuth() {
        isAuthenticated = KeychainManager.getBlueskyAccessToken() != nil
    }

    @MainActor
    public func logout() {
        KeychainManager.deleteBlueskyTokens()
        isAuthenticated = false
        error = nil
    }

    // MARK: - Timeline Methods

    @MainActor
    public func getTimeline(limit _: Int = 50, cursor _: String? = nil) async -> TimelineResponse? {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let timeline: TimelineResponse = try await authenticatedRequest(
                endpoint: "app.bsky.feed.getTimeline",
                method: "GET",
            )
            self.timeline = timeline
            print("Fetched \(timeline.feed.count) posts")
            return timeline
        } catch {
            print("error \(error)")
            self.error = BlueskyError(error: "Failed to fetch timeline", message: error.localizedDescription)
            return nil
        }
    }

    // MARK: - Profile Methods

    public struct GetProfileRequest: Codable, Sendable {
        public let actor: String

        public init(actor: String) {
            self.actor = actor
        }
    }

    @MainActor
    public func getMyProfile() async {
        guard let actor = KeychainManager.getBlueskyHandle() else {
            return
        }
        profile = await getProfile(actor: actor)
    }

    @MainActor
    public func getProfile(actor: String) async -> ProfileViewResponse? {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            _ = GetProfileRequest(actor: actor)
            let profile: ProfileViewResponse = try await authenticatedRequest(
                endpoint: "app.bsky.actor.getProfile",
                method: "GET",
                queryItems: [URLQueryItem(name: "actor", value: actor)],
            )
            print("Fetched profile for: \(profile.handle)")
            return profile
        } catch {
            print("error \(error)")
            self.error = BlueskyError(error: "Failed to fetch profile", message: error.localizedDescription)
            return nil
        }
    }

    // MARK: - Post Methods

    @MainActor
    public func createPost(text: String, replyTo: String? = nil) async {
        guard let did = KeychainManager.getBlueskyHDID() else {
            print("didless")
            return
        }
        isLoading = true
        error = nil

        defer { isLoading = false }

        do {
            let request = try CreatePostRequest(did: did, text: text, replyTo: replyTo)
            let response: CreatePostResponse = try await authenticatedRequest(
                endpoint: "com.atproto.repo.createRecord",
                method: "POST",
                body: request,
            )
            print("Created post with URI: \(response.uri)")

            // Wait half a second then refresh timeline
            try await Task.sleep(for: .milliseconds(500))
            let _ = await getTimeline()
        } catch {
            print("error \(error)")
            self.error = BlueskyError(error: "Failed to create post", message: error.localizedDescription)
        }
    }

    @MainActor
    public func deletePost(uri: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let _: EmptyResponse = try await authenticatedRequest(
                endpoint: "app.bsky.feed.deletePost",
                method: "POST",
                body: ["uri": uri],
            )
            print("Deleted post: \(uri)")
        } catch {
            self.error = BlueskyError(error: "Failed to delete post", message: error.localizedDescription)
        }
    }

    // MARK: - Like Methods

    @MainActor
    public func likePost(uri: String, cid: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let _: EmptyResponse = try await authenticatedRequest(
                endpoint: "app.bsky.feed.like",
                method: "POST",
                body: ["uri": uri, "cid": cid],
            )
            print("Liked post: \(uri)")
        } catch {
            self.error = BlueskyError(error: "Failed to like post", message: error.localizedDescription)
        }
    }

    @MainActor
    public func unlikePost(uri: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let _: EmptyResponse = try await authenticatedRequest(
                endpoint: "app.bsky.feed.unlike",
                method: "POST",
                body: ["uri": uri],
            )
            print("Unliked post: \(uri)")
        } catch {
            self.error = BlueskyError(error: "Failed to unlike post", message: error.localizedDescription)
        }
    }

    private func refreshSession() async throws -> CreateSessionResponse {
        guard let refreshToken = KeychainManager.getBlueskyRefreshToken() else {
            throw BlueskyError(error: "auth_required", message: "No refresh token available")
        }

        let endpoint = baseURL.appendingPathComponent("/xrpc/com.atproto.server.refreshSession")

        let response: CreateSessionResponse = try await httpClient.sendRequest(
            endpoint,
            method: "POST",
            body: nil,
            headers: ["Authorization": "Bearer \(refreshToken)"],
        )

        // Save new tokens
        try KeychainManager.saveBlueskyTokens(accessToken: response.accessJwt, refreshToken: response.refreshJwt)
        return response
    }
}

// MARK: - Core Models

public struct BlueskyError: Codable, Error, Sendable {
    public let error: String
    public let message: String
}

public struct CreateSessionRequest: Codable, Sendable {
    public let identifier: String
    public let password: String

    public init(identifier: String, password: String) {
        self.identifier = identifier
        self.password = password
    }
}

public struct CreateSessionResponse: Codable, Sendable {
    public let accessJwt: String
    public let refreshJwt: String
    public let handle: String
    public let did: String
}

// MARK: - HTTP Client Protocol

public protocol HTTPClient: Sendable {
    func sendRequest<T: Decodable & Sendable>(_ url: URL,
                                              method: String,
                                              body: (any Encodable & Sendable)?,
                                              headers: [String: String]) async throws -> T
}

// MARK: - URLSession-based HTTP Client

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(session: URLSession = .shared,
                decoder: JSONDecoder = JSONDecoder(),
                encoder: JSONEncoder = JSONEncoder())
    {
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
    }

    public func sendRequest<T: Decodable & Sendable>(_ url: URL,
                                                     method: String,
                                                     body: (any Encodable & Sendable)?,
                                                     headers: [String: String]) async throws -> T
    {
        var request = URLRequest(url: url)
        request.httpMethod = method

        // Add headers
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        // Add body if present
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // Handle error responses
        guard 200 ... 299 ~= httpResponse.statusCode else {
            // Try to decode error response
            if let error = try? decoder.decode(BlueskyError.self, from: data) {
                throw error
            }
            throw URLError(.badServerResponse)
        }

        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Timeline Models

public struct TimelineResponse: Codable, Sendable {
    public let cursor: String?
    public let feed: [FeedViewPost]
}

public struct FeedViewPost: Codable, Sendable {
    public let post: PostModelView
    public let reply: ReplyRef?
}

public struct PostModelView: Codable, Sendable {
    public let uri: String
    public let cid: String
    public let author: ActorProfile
    public let record: PostRecord
    public let likeCount: Int
    public let repostCount: Int
    public let indexedAt: String
}

public struct ActorProfile: Codable, Sendable {
    public let did: String
    public let handle: String
    public let displayName: String?
    public let avatar: String?
    public let description: String?
}

public struct ReplyRef: Codable, Sendable {
    public let parent: PostModelView
    public let root: PostModelView
}

// MARK: - Profile Models

public struct ProfileViewResponse: Codable, Sendable {
    public let did: String
    public let handle: String
    public let displayName: String?
    public let description: String?
    public let avatar: String?
    public let followersCount: Int
    public let followsCount: Int
    public let postsCount: Int
}

// MARK: - Post Models

public struct CreatePostRequest: Codable, Sendable {
    let repo: String
    let collection: String
    let record: PostRecord

    public init(did: String, text: String, replyTo _: String? = nil) throws {
        // Validate text length before creating request
        guard text.count <= 300 else {
            throw BlueskyError(error: "InvalidText", message: "Post text must not exceed 300 characters")
        }
        collection = "app.bsky.feed.post"
        repo = did
        record = PostRecord(text: text, createdAt: ISO8601DateFormatter().string(from: Date()))
    }
}

public struct PostRecord: Codable, Sendable {
    public let text: String
    public let createdAt: String
    // Add other optional fields like reply, embed, etc. as needed
}

public struct CreatePostResponse: Codable, Sendable {
    public let uri: String
    public let cid: String
}

private struct EmptyResponse: Codable, Sendable {}
