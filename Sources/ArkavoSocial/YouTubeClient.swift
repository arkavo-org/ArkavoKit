#if canImport(AppKit)
import AppKit
#endif
import CommonCrypto
import Foundation
import Network
import SwiftUI

public actor YouTubeClient: ObservableObject {
    // MARK: - Published Properties

    @MainActor @Published public private(set) var isAuthenticated = false
    @MainActor @Published public private(set) var isLoading = false
    @MainActor @Published public private(set) var error: YouTubeError?
    @MainActor @Published public private(set) var channelInfo: YouTubeChannelInfo?

    // MARK: - Private Properties

    private let clientId: String
    private let clientSecret: String
    private let keychainServiceBase = "com.arkavo.youtube"
    private var codeVerifier: String?
    private var currentRedirectUri: String?
    #if os(macOS)
    private var callbackServer: OAuthCallbackServer?
    #endif

    private enum KeychainKey {
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let tokenExpiration = "token_expiration"
        static let channelId = "channel_id"
    }

    // MARK: - Initialization

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret

        Task { @MainActor in
            await loadStoredTokens()
        }
    }

    // MARK: - PKCE Support

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Token Management

    private func loadStoredTokens() async {
        let accessToken = KeychainManager.getValue(
            service: keychainServiceBase,
            account: KeychainKey.accessToken,
        )

        await MainActor.run {
            isAuthenticated = accessToken != nil
        }

        if accessToken != nil {
            await fetchChannelInfo()
        }
    }

    private func saveTokens(accessToken: String, refreshToken: String, expiresIn: Int) {
        let expirationDate = Date().addingTimeInterval(TimeInterval(expiresIn))

        KeychainManager.save(
            value: accessToken,
            service: keychainServiceBase,
            account: KeychainKey.accessToken,
        )

        KeychainManager.save(
            value: refreshToken,
            service: keychainServiceBase,
            account: KeychainKey.refreshToken,
        )

        KeychainManager.save(
            value: ISO8601DateFormatter().string(from: expirationDate),
            service: keychainServiceBase,
            account: KeychainKey.tokenExpiration,
        )
    }

    @MainActor
    public func logout() {
        Task { @MainActor in
            try? KeychainManager.delete(service: keychainServiceBase, account: KeychainKey.accessToken)
            try? KeychainManager.delete(service: keychainServiceBase, account: KeychainKey.refreshToken)
            try? KeychainManager.delete(service: keychainServiceBase, account: KeychainKey.tokenExpiration)
            try? KeychainManager.delete(service: keychainServiceBase, account: KeychainKey.channelId)

            isAuthenticated = false
            channelInfo = nil
        }
    }

    // MARK: - Authentication

    private func buildAuthURL(redirectUri: String, state: String) -> URL {
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            // Minimum scopes for our usage:
            // `youtube.force-ssl`: covers liveBroadcasts (create/bind/transition/end),
            //   liveStreams (list/create), liveChat (read/insert), and reading own
            //   channel info via `mine=true`. Replaces the broader `youtube` scope.
            // `youtube.upload`: required for video uploads from Library.
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/youtube.force-ssl https://www.googleapis.com/auth/youtube.upload"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    #if os(macOS)
    /// Authenticate using a local HTTP server to receive the OAuth callback (macOS only)
    public func authenticateWithLocalServer() async throws {
        await MainActor.run {
            isLoading = true
            error = nil
        }

        // Clean up any existing server
        callbackServer?.stop()
        let server = OAuthCallbackServer()
        callbackServer = server

        do {
            let state = UUID().uuidString

            // Start server and get the callback in a detached task
            let serverTask = Task.detached { [state] in
                try await server.startAndWaitForCallback(state: state, timeout: 300)
            }

            // Brief delay to ensure server is ready and has a port
            try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds

            // Store the redirect URI for token exchange
            let redirectUri = server.redirectUri
            currentRedirectUri = redirectUri

            // Build auth URL with the dynamic localhost redirect
            let authURL = buildAuthURL(redirectUri: redirectUri, state: state)

            // Open browser for authentication
            await MainActor.run {
                NSWorkspace.shared.open(authURL)
            }

            // Wait for the callback with the authorization code
            let code = try await serverTask.value

            // Exchange code for tokens
            try await exchangeCodeForTokens(code)
            await fetchChannelInfo()

            await MainActor.run {
                isAuthenticated = true
                isLoading = false
            }

        } catch let oauthError as OAuthCallbackServer.OAuthError {
            callbackServer?.stop()
            callbackServer = nil

            let youtubeError: YouTubeError
            switch oauthError {
            case .cancelled:
                youtubeError = .userCancelled
            case .timeout:
                youtubeError = .authSessionFailed
            case let .oauthError(message):
                youtubeError = .googleError(message)
            default:
                youtubeError = .unknown(oauthError)
            }
            await MainActor.run {
                self.error = youtubeError
                isLoading = false
            }
            throw youtubeError

        } catch {
            callbackServer?.stop()
            callbackServer = nil
            let youtubeError = error as? YouTubeError ?? .unknown(error)
            await MainActor.run {
                self.error = youtubeError
                isLoading = false
            }
            throw error
        }

        callbackServer?.stop()
        callbackServer = nil
    }
    #endif

    public func handleCallback(_ url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw YouTubeError.invalidCallback
        }

        await MainActor.run {
            isLoading = true
            error = nil
        }

        do {
            try await exchangeCodeForTokens(code)
            await fetchChannelInfo()
            await MainActor.run {
                isAuthenticated = true
            }
        } catch {
            await MainActor.run {
                self.error = error as? YouTubeError ?? .unknown(error)
            }
            throw error
        }

        await MainActor.run {
            isLoading = false
        }
    }

    // Make exchangeCodeForTokens public so it can be used directly with authorization code
    public func exchangeCodeForTokens(_ code: String) async throws {
        guard let redirectUri = currentRedirectUri else {
            throw YouTubeError.invalidCallback
        }

        let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var parameters = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirectUri,
        ]

        // Add PKCE code_verifier if available
        if let verifier = codeVerifier {
            parameters["code_verifier"] = verifier
        }

        request.httpBody = parameters.percentEncoded()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let tokenResponse = try JSONDecoder().decode(YouTubeTokenResponse.self, from: data)
            saveTokens(
                accessToken: tokenResponse.access_token,
                refreshToken: tokenResponse.refresh_token ?? "",
                expiresIn: tokenResponse.expires_in,
            )
        } else {
            // Parse error response for better error messages
            if let errorResponse = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data) {
                throw YouTubeError.googleError(errorResponse.error_description ?? errorResponse.error)
            }
            throw YouTubeError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken = KeychainManager.getValue(
            service: keychainServiceBase,
            account: KeychainKey.refreshToken,
        ) else {
            throw YouTubeError.noRefreshToken
        }

        let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let parameters = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]

        request.httpBody = parameters.percentEncoded()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let tokenResponse = try JSONDecoder().decode(YouTubeTokenResponse.self, from: data)
            saveTokens(
                accessToken: tokenResponse.access_token,
                refreshToken: refreshToken, // Keep existing refresh token
                expiresIn: tokenResponse.expires_in,
            )
        } else {
            throw YouTubeError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - API Methods

    private func getValidAccessToken() async throws -> String {
        if let expirationString = KeychainManager.getValue(
            service: keychainServiceBase,
            account: KeychainKey.tokenExpiration,
        ),
            let expirationDate = ISO8601DateFormatter().date(from: expirationString),
            let accessToken = KeychainManager.getValue(
                service: keychainServiceBase,
                account: KeychainKey.accessToken,
            ),
            expirationDate > Date().addingTimeInterval(60)
        {
            return accessToken
        }

        // Token expired or will expire soon, try to refresh
        try await refreshAccessToken()

        guard let newAccessToken = KeychainManager.getValue(
            service: keychainServiceBase,
            account: KeychainKey.accessToken,
        ) else {
            throw YouTubeError.noAccessToken
        }

        return newAccessToken
    }

    private func makeAuthorizedRequest(url: URL) async throws -> URLRequest {
        let accessToken = try await getValidAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func fetchChannelInfo() async {
        do {
            let url = URL(string: "https://www.googleapis.com/youtube/v3/channels?part=snippet,statistics&mine=true")!
            let request = try await makeAuthorizedRequest(url: url)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw YouTubeError.invalidResponse
            }

            if httpResponse.statusCode == 200 {
                let channelResponse = try JSONDecoder().decode(YouTubeChannelResponse.self, from: data)
                if let channel = channelResponse.items.first {
                    let info = YouTubeChannelInfo(
                        id: channel.id,
                        title: channel.snippet.title,
                        description: channel.snippet.description,
                        thumbnailUrl: channel.snippet.thumbnails.default.url,
                        subscriberCount: Int(channel.statistics.subscriberCount) ?? 0,
                        videoCount: Int(channel.statistics.videoCount) ?? 0,
                        viewCount: Int(channel.statistics.viewCount) ?? 0,
                    )

                    // Save channel ID for future use
                    KeychainManager.save(
                        value: channel.id,
                        service: keychainServiceBase,
                        account: KeychainKey.channelId,
                    )

                    await MainActor.run {
                        self.channelInfo = info
                    }
                }
            } else {
                throw YouTubeError.httpError(statusCode: httpResponse.statusCode)
            }
        } catch {
            await MainActor.run {
                self.error = error as? YouTubeError ?? .unknown(error)
            }
        }
    }

    // MARK: - Live Streaming API

    /// Fetches the stream key from YouTube Live Streaming API
    /// If no stream exists, creates a reusable one automatically
    /// Returns the stream key (ingestion stream name) for the user's live stream
    public func fetchStreamKey() async throws -> String? {
        let url = URL(string: "https://www.googleapis.com/youtube/v3/liveStreams?part=cdn,snippet&mine=true")!
        let request = try await makeAuthorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let streamResponse = try JSONDecoder().decode(YouTubeLiveStreamResponse.self, from: data)
            // Return the first active stream's key
            if let stream = streamResponse.items.first {
                return stream.cdn.ingestionInfo.streamName
            }
            // No streams exist - create one automatically
            return try await createLiveStream()
        } else if httpResponse.statusCode == 403 {
            throw YouTubeError.googleError("Live streaming is not enabled for this YouTube account. Enable it in YouTube Studio first.")
        } else {
            if let errorResponse = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data) {
                throw YouTubeError.googleError(errorResponse.error_description ?? errorResponse.error)
            }
            throw YouTubeError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    /// Creates a new reusable live stream and returns its stream key
    private func createLiveStream() async throws -> String {
        let url = URL(string: "https://www.googleapis.com/youtube/v3/liveStreams?part=snippet,cdn,contentDetails")!

        var request = try await makeAuthorizedRequest(url: url)
        request.httpMethod = "POST"

        let requestBody: [String: Any] = [
            "snippet": [
                "title": "Arkavo Creator Stream"
            ],
            "cdn": [
                "ingestionType": "rtmp",
                "frameRate": "30fps",
                "resolution": "1080p"
            ],
            "contentDetails": [
                "isReusable": true
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }

        if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
            let stream = try JSONDecoder().decode(YouTubeLiveStreamResponse.LiveStream.self, from: data)
            return stream.cdn.ingestionInfo.streamName
        } else if httpResponse.statusCode == 403 {
            throw YouTubeError.googleError("Cannot create live stream. Live streaming may not be enabled for this account.")
        } else {
            if let errorResponse = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data) {
                throw YouTubeError.googleError(errorResponse.error_description ?? errorResponse.error)
            }
            throw YouTubeError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Broadcast Lifecycle

    /// Creates a broadcast, binds it to a stream, and returns the broadcast ID.
    /// Call this before starting RTMP streaming to YouTube.
    /// - Parameter privacyStatus: One of "public", "unlisted", "private". Defaults to "public" for backward compatibility.
    public func createAndBindBroadcast(title: String, privacyStatus: String = "public") async throws -> String {
        let allowedPrivacy: Set<String> = ["public", "unlisted", "private"]
        let validatedPrivacy = allowedPrivacy.contains(privacyStatus) ? privacyStatus : "public"
        // 1. Get or create a live stream
        let url = URL(string: "https://www.googleapis.com/youtube/v3/liveStreams?part=cdn,snippet&mine=true")!
        let listRequest = try await makeAuthorizedRequest(url: url)
        let (listData, listResponse) = try await URLSession.shared.data(for: listRequest)

        guard let listHttp = listResponse as? HTTPURLResponse, listHttp.statusCode == 200 else {
            throw YouTubeError.googleError("Failed to list live streams")
        }

        let streamResponse = try JSONDecoder().decode(YouTubeLiveStreamResponse.self, from: listData)
        let streamId: String
        if let existing = streamResponse.items.first {
            streamId = existing.id
        } else {
            streamId = try await createLiveStreamAndReturnId()
        }

        // 2. Create a broadcast
        let broadcastURL = URL(string: "https://www.googleapis.com/youtube/v3/liveBroadcasts?part=snippet,contentDetails,status")!
        var broadcastRequest = try await makeAuthorizedRequest(url: broadcastURL)
        broadcastRequest.httpMethod = "POST"

        // 60s buffer tolerates request latency, clock skew, and YouTube's own
        // "scheduledStartTime must be in the future" validation. 10s was too tight.
        let scheduledStart = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        let broadcastBody: [String: Any] = [
            "snippet": [
                "title": title.isEmpty ? "Arkavo Creator Live" : title,
                "scheduledStartTime": scheduledStart
            ],
            "contentDetails": [
                "enableAutoStart": false,
                "enableAutoStop": true
            ],
            "status": [
                "privacyStatus": validatedPrivacy
            ]
        ]
        broadcastRequest.httpBody = try JSONSerialization.data(withJSONObject: broadcastBody)

        let (broadcastData, broadcastResponse) = try await URLSession.shared.data(for: broadcastRequest)
        guard let broadcastHttp = broadcastResponse as? HTTPURLResponse,
              (200...201).contains(broadcastHttp.statusCode) else {
            if let errorResponse = try? JSONDecoder().decode(GoogleErrorResponse.self, from: broadcastData) {
                throw YouTubeError.googleError("Broadcast creation failed: \(errorResponse.error_description ?? errorResponse.error)")
            }
            let code = (broadcastResponse as? HTTPURLResponse)?.statusCode ?? 0
            throw YouTubeError.googleError("Broadcast creation failed (HTTP \(code))")
        }

        let broadcast = try JSONDecoder().decode(YouTubeBroadcastResponse.self, from: broadcastData)
        let broadcastId = broadcast.id

        // 3. Bind the stream to the broadcast
        let bindURL = URL(string: "https://www.googleapis.com/youtube/v3/liveBroadcasts/bind?id=\(broadcastId)&part=id,contentDetails&streamId=\(streamId)")!
        var bindRequest = try await makeAuthorizedRequest(url: bindURL)
        bindRequest.httpMethod = "POST"
        bindRequest.httpBody = Data() // empty body required

        let (_, bindResponse) = try await URLSession.shared.data(for: bindRequest)
        guard let bindHttp = bindResponse as? HTTPURLResponse, bindHttp.statusCode == 200 else {
            throw YouTubeError.googleError("Failed to bind stream to broadcast")
        }

        return broadcastId
    }

    /// Check the current lifecycle status of a broadcast
    public func getBroadcastStatus(broadcastId: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/youtube/v3/liveBroadcasts?id=\(broadcastId)&part=status")!
        let request = try await makeAuthorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw YouTubeError.googleError("Failed to get broadcast status")
        }

        struct BroadcastListResponse: Codable {
            let items: [YouTubeBroadcastResponse]
        }
        let listResponse = try JSONDecoder().decode(BroadcastListResponse.self, from: data)
        return listResponse.items.first?.status?.lifeCycleStatus ?? "unknown"
    }

    /// Transitions a broadcast to "live" status via testing → live.
    /// Waits for the broadcast to reach "ready" state first.
    public func transitionBroadcastToLive(broadcastId: String) async throws {
        // Wait for broadcast to reach "ready" state (YouTube verifies the stream)
        for i in 1...12 {
            let status = try await getBroadcastStatus(broadcastId: broadcastId)
            print("[YouTubeClient] Broadcast status: \(status) (check \(i)/12)")
            if status == "ready" || status == "testing" || status == "live" {
                break
            }
            if i == 12 {
                throw YouTubeError.googleError("Broadcast stuck in '\(status)' state. YouTube may not be receiving audio+video.")
            }
            try await Task.sleep(for: .seconds(5))
        }

        // Transition: ready → testing
        let currentStatus = try await getBroadcastStatus(broadcastId: broadcastId)
        if currentStatus == "ready" {
            try await transitionBroadcast(broadcastId: broadcastId, to: "testing")
            // Wait for testing state to be confirmed
            try await Task.sleep(for: .seconds(5))
        }

        // Transition: testing → live (skip if already live)
        let afterTesting = try await getBroadcastStatus(broadcastId: broadcastId)
        if afterTesting == "testing" {
            try await transitionBroadcast(broadcastId: broadcastId, to: "live")
        }
    }

    /// Transition a broadcast to a specific status
    private func transitionBroadcast(broadcastId: String, to status: String) async throws {
        let url = URL(string: "https://www.googleapis.com/youtube/v3/liveBroadcasts/transition?broadcastStatus=\(status)&id=\(broadcastId)&part=status")!
        var request = try await makeAuthorizedRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }

        // Log the full response for debugging
        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            print("[YouTubeClient] Transition to '\(status)' failed (HTTP \(httpResponse.statusCode)): \(body)")
        }

        // 412 means stream isn't active yet — caller should retry
        if httpResponse.statusCode == 412 {
            throw YouTubeError.googleError("Stream not active yet for '\(status)' transition.")
        }

        guard httpResponse.statusCode == 200 else {
            // Parse YouTube API v3 error format
            if let apiError = try? JSONDecoder().decode(YouTubeAPIError.self, from: data),
               let reason = apiError.error.errors.first?.reason {
                throw YouTubeError.googleError("Transition to '\(status)': \(reason) - \(apiError.error.message)")
            }
            if let errorResponse = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data) {
                throw YouTubeError.googleError("Transition to '\(status)': \(errorResponse.error_description ?? errorResponse.error)")
            }
            throw YouTubeError.httpError(statusCode: httpResponse.statusCode)
        }

        print("[YouTubeClient] Broadcast transitioned to '\(status)'")
    }

    /// Ends a broadcast by transitioning to "complete".
    public func endBroadcast(broadcastId: String) async throws {
        let url = URL(string: "https://www.googleapis.com/youtube/v3/liveBroadcasts/transition?broadcastStatus=complete&id=\(broadcastId)&part=status")!
        var request = try await makeAuthorizedRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            // Best-effort — don't throw on end
            return
        }
    }

    /// Fetches the liveChatId for a broadcast
    public func getLiveChatId(broadcastId: String) async throws -> String? {
        let url = URL(string: "https://www.googleapis.com/youtube/v3/liveBroadcasts?id=\(broadcastId)&part=snippet")!
        let request = try await makeAuthorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        struct BroadcastListResponse: Codable {
            let items: [YouTubeBroadcastResponse]
        }
        let listResponse = try JSONDecoder().decode(BroadcastListResponse.self, from: data)
        return listResponse.items.first?.snippet?.liveChatId
    }

    /// Fetches live chat messages using OAuth token (not API key)
    public func fetchLiveChatMessages(liveChatId: String, pageToken: String?) async throws -> YouTubeLiveChatResult {
        var urlComponents = URLComponents(string: "https://www.googleapis.com/youtube/v3/liveChat/messages")!
        urlComponents.queryItems = [
            URLQueryItem(name: "liveChatId", value: liveChatId),
            URLQueryItem(name: "part", value: "snippet,authorDetails"),
        ]
        if let pageToken = pageToken {
            urlComponents.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        let request = try await makeAuthorizedRequest(url: urlComponents.url!)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw YouTubeError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let chatResponse = try JSONDecoder().decode(YouTubeLiveChatResponse.self, from: data)
        return YouTubeLiveChatResult(
            messages: chatResponse.items,
            nextPageToken: chatResponse.nextPageToken,
            pollingIntervalMs: chatResponse.pollingIntervalMillis
        )
    }

    /// Creates a live stream and returns its ID (not just the stream key)
    private func createLiveStreamAndReturnId() async throws -> String {
        let url = URL(string: "https://www.googleapis.com/youtube/v3/liveStreams?part=snippet,cdn,contentDetails")!
        var request = try await makeAuthorizedRequest(url: url)
        request.httpMethod = "POST"

        let requestBody: [String: Any] = [
            "snippet": ["title": "Arkavo Creator Stream"],
            "cdn": [
                "ingestionType": "rtmp",
                "frameRate": "30fps",
                "resolution": "1080p"
            ],
            "contentDetails": ["isReusable": true]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...201).contains(httpResponse.statusCode) else {
            throw YouTubeError.googleError("Failed to create live stream")
        }

        let stream = try JSONDecoder().decode(YouTubeLiveStreamResponse.LiveStream.self, from: data)
        return stream.id
    }

    // MARK: - Video Upload

    /// Privacy status for uploaded videos.
    public enum VideoPrivacy: String, Sendable, CaseIterable {
        case privateVideo = "private"
        case unlisted
        case publicVideo = "public"

        public var displayName: String {
            switch self {
            case .privateVideo: "Private"
            case .unlisted: "Unlisted"
            case .publicVideo: "Public"
            }
        }
    }

    /// Metadata for a video upload.
    public struct VideoUploadMetadata: Sendable {
        public let title: String
        public let description: String
        public let tags: [String]
        public let privacy: VideoPrivacy
        public let categoryId: String

        /// `categoryId` 22 is "People & Blogs" — a safe default for personal content.
        public init(
            title: String,
            description: String = "",
            tags: [String] = [],
            privacy: VideoPrivacy = .privateVideo,
            categoryId: String = "22"
        ) {
            self.title = title
            self.description = description
            self.tags = tags
            self.privacy = privacy
            self.categoryId = categoryId
        }
    }

    /// Upload a video file to YouTube using the resumable upload protocol.
    ///
    /// Uses a two-step flow:
    ///   1. POST to `uploadType=resumable` with metadata — server returns an upload URL in `Location`.
    ///   2. PUT the video bytes in chunks to that URL, reporting progress.
    ///
    /// - Parameters:
    ///   - fileURL: local video file to upload. Must be readable for the duration of the call.
    ///   - metadata: title, description, tags, privacy.
    ///   - mimeType: MIME type (e.g. "video/quicktime", "video/mp4"). Defaults to quicktime.
    ///   - onProgress: bytes-sent / total-bytes fraction in [0, 1]. Called on an arbitrary queue.
    /// - Returns: The YouTube video ID.
    public func uploadVideo(
        fileURL: URL,
        metadata: VideoUploadMetadata,
        mimeType: String = "video/quicktime",
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let totalSize = attrs[.size] as? Int64, totalSize > 0 else {
            throw YouTubeError.googleError("Upload source is empty or unreadable")
        }

        // Step 1: initiate the resumable session
        let uploadURL = try await initiateResumableUpload(
            metadata: metadata,
            totalSize: totalSize,
            mimeType: mimeType
        )

        // Step 2: stream chunks
        return try await uploadResumableChunks(
            to: uploadURL,
            fileURL: fileURL,
            totalSize: totalSize,
            mimeType: mimeType,
            onProgress: onProgress
        )
    }

    private func initiateResumableUpload(
        metadata: VideoUploadMetadata,
        totalSize: Int64,
        mimeType: String
    ) async throws -> URL {
        let url = URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!
        var request = try await makeAuthorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue("\(totalSize)", forHTTPHeaderField: "X-Upload-Content-Length")

        let body: [String: Any] = [
            "snippet": [
                "title": metadata.title,
                "description": metadata.description,
                "tags": metadata.tags,
                "categoryId": metadata.categoryId
            ],
            "status": [
                "privacyStatus": metadata.privacy.rawValue,
                "selfDeclaredMadeForKids": false
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if let apiError = try? JSONDecoder().decode(YouTubeAPIError.self, from: data),
               let reason = apiError.error.errors.first?.reason {
                throw YouTubeError.googleError("Upload init failed: \(reason) — \(apiError.error.message)")
            }
            throw YouTubeError.httpError(statusCode: http.statusCode)
        }

        // Google returns the session URL in the Location header (case-insensitive)
        guard let location = http.value(forHTTPHeaderField: "Location") ?? http.value(forHTTPHeaderField: "location"),
              let sessionURL = URL(string: location) else {
            throw YouTubeError.googleError("Upload session URL missing from response")
        }
        return sessionURL
    }

    /// Upload chunk size — 8 MiB, a multiple of 256 KiB as required by the Google
    /// resumable upload protocol. Large enough to keep overhead low, small enough
    /// to give responsive progress and manageable retry on flaky networks.
    private static let uploadChunkSize: Int = 8 * 1024 * 1024

    /// Maximum retry attempts per chunk on transient (5xx / network) failure.
    private static let uploadMaxAttempts: Int = 5

    /// Dedicated URLSession for resumable uploads with stall protection.
    /// `timeoutIntervalForRequest` triggers if no bytes flow for the duration;
    /// `timeoutIntervalForResource` caps total time per chunk PUT.
    private static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60   // stalls > 60s are treated as transient errors
        config.timeoutIntervalForResource = 600 // hard cap per chunk
        return URLSession(configuration: config)
    }()

    /// Parse the byte offset of the next chunk from a YouTube `Range` header.
    /// Header format: `bytes=0-N` (inclusive end). Returns N+1 (next byte to send),
    /// or nil if the header is missing/unparseable.
    static func nextOffsetFromRangeHeader(_ header: String?) -> Int64? {
        guard let header = header,
              let dashIdx = header.firstIndex(of: "-") else { return nil }
        let endStr = header[header.index(after: dashIdx)...]
        guard let serverEnd = Int64(endStr) else { return nil }
        return serverEnd + 1
    }

    private func uploadResumableChunks(
        to uploadURL: URL,
        fileURL: URL,
        totalSize: Int64,
        mimeType: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var offset: Int64 = 0
        let chunkSize = Int64(Self.uploadChunkSize)

        while offset < totalSize {
            try Task.checkCancellation()

            let remaining = totalSize - offset
            let thisChunk = Swift.min(chunkSize, remaining)
            let endByte = offset + thisChunk - 1

            try handle.seek(toOffset: UInt64(offset))
            let chunkData = try handle.read(upToCount: Int(thisChunk)) ?? Data()
            guard chunkData.count == Int(thisChunk) else {
                throw YouTubeError.googleError("Unexpected read length at offset \(offset)")
            }

            // Try this chunk with bounded exponential backoff on transient errors.
            // 5xx and URLError network issues are retried; 4xx is fatal.
            var attempt = 0
            chunkAttempt: while true {
                attempt += 1
                let result: ChunkOutcome
                do {
                    result = try await sendUploadChunk(
                        to: uploadURL,
                        chunk: chunkData,
                        offset: offset,
                        endByte: endByte,
                        totalSize: totalSize,
                        mimeType: mimeType
                    )
                } catch let urlError as URLError where attempt < Self.uploadMaxAttempts {
                    // Transient network issue (timeout, lost connection, etc.).
                    let delaySeconds = Double(1 << (attempt - 1))  // 1, 2, 4, 8, 16
                    try await Task.sleep(for: .seconds(delaySeconds))
                    // Re-query the server for the byte offset it actually has;
                    // it may have committed bytes before the error reached us.
                    if let probed = try? await probeUploadOffset(uploadURL: uploadURL, totalSize: totalSize) {
                        if let videoId = probed.completedVideoId {
                            onProgress?(1.0)
                            return videoId
                        }
                        offset = probed.nextOffset ?? offset
                    }
                    _ = urlError  // silence unused
                    continue chunkAttempt
                }

                switch result {
                case .completed(let videoId):
                    onProgress?(1.0)
                    return videoId

                case .resumeIncomplete(let serverNextOffset):
                    offset = serverNextOffset ?? (offset + thisChunk)
                    onProgress?(Double(offset) / Double(totalSize))
                    break chunkAttempt

                case .transient(let statusCode):
                    guard attempt < Self.uploadMaxAttempts else {
                        throw YouTubeError.googleError("Upload chunk failed after \(attempt) attempts (HTTP \(statusCode))")
                    }
                    let delaySeconds = Double(1 << (attempt - 1))
                    try await Task.sleep(for: .seconds(delaySeconds))
                    if let probed = try? await probeUploadOffset(uploadURL: uploadURL, totalSize: totalSize) {
                        if let videoId = probed.completedVideoId {
                            onProgress?(1.0)
                            return videoId
                        }
                        offset = probed.nextOffset ?? offset
                    }
                    continue chunkAttempt
                }
            }
        }

        // Control should only reach here if the last chunk's response was 308 with
        // server-reported offset == totalSize (no terminal 200 yet). Probe for it.
        if let probed = try? await probeUploadOffset(uploadURL: uploadURL, totalSize: totalSize),
           let videoId = probed.completedVideoId {
            onProgress?(1.0)
            return videoId
        }
        throw YouTubeError.googleError("Upload completed bytes but no video ID returned")
    }

    private enum ChunkOutcome {
        case completed(videoId: String)
        case resumeIncomplete(nextOffset: Int64?)
        case transient(statusCode: Int)
    }

    private func sendUploadChunk(
        to uploadURL: URL,
        chunk: Data,
        offset: Int64,
        endByte: Int64,
        totalSize: Int64,
        mimeType: String
    ) async throws -> ChunkOutcome {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(chunk.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("bytes \(offset)-\(endByte)/\(totalSize)", forHTTPHeaderField: "Content-Range")
        request.httpBody = chunk

        let (data, response) = try await Self.uploadSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }

        switch http.statusCode {
        case 200, 201:
            struct VideoResource: Codable { let id: String }
            let resource = try JSONDecoder().decode(VideoResource.self, from: data)
            return .completed(videoId: resource.id)

        case 308:
            let header = http.value(forHTTPHeaderField: "Range") ?? http.value(forHTTPHeaderField: "range")
            return .resumeIncomplete(nextOffset: Self.nextOffsetFromRangeHeader(header))

        case 401, 403:
            throw YouTubeError.googleError("Upload unauthorized (HTTP \(http.statusCode)) — token may be missing youtube.upload scope")

        case 500, 502, 503, 504:
            return .transient(statusCode: http.statusCode)

        default:
            if let apiError = try? JSONDecoder().decode(YouTubeAPIError.self, from: data),
               let reason = apiError.error.errors.first?.reason {
                throw YouTubeError.googleError("Upload chunk failed (HTTP \(http.statusCode)): \(reason)")
            }
            throw YouTubeError.httpError(statusCode: http.statusCode)
        }
    }

    private struct UploadProbeResult {
        let nextOffset: Int64?
        let completedVideoId: String?
    }

    /// Query the upload session for current byte offset. Per the resumable protocol,
    /// PUT with `Content-Range: bytes *​/<totalSize>` and an empty body returns 308 + Range,
    /// or 200/201 if the upload already completed server-side.
    private func probeUploadOffset(uploadURL: URL, totalSize: Int64) async throws -> UploadProbeResult {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("bytes */\(totalSize)", forHTTPHeaderField: "Content-Range")
        request.httpBody = Data()

        let (data, response) = try await Self.uploadSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }
        switch http.statusCode {
        case 200, 201:
            struct VideoResource: Codable { let id: String }
            if let resource = try? JSONDecoder().decode(VideoResource.self, from: data) {
                return UploadProbeResult(nextOffset: nil, completedVideoId: resource.id)
            }
            return UploadProbeResult(nextOffset: totalSize, completedVideoId: nil)
        case 308:
            let header = http.value(forHTTPHeaderField: "Range") ?? http.value(forHTTPHeaderField: "range")
            return UploadProbeResult(
                nextOffset: Self.nextOffsetFromRangeHeader(header) ?? 0,
                completedVideoId: nil
            )
        default:
            throw YouTubeError.httpError(statusCode: http.statusCode)
        }
    }
}

// MARK: - Supporting Types

struct YouTubeBroadcastResponse: Codable {
    let id: String
    let snippet: Snippet?
    let status: Status?

    struct Snippet: Codable {
        let liveChatId: String?
    }

    struct Status: Codable {
        let lifeCycleStatus: String?
    }
}

struct YouTubeLiveStreamResponse: Codable {
    let items: [LiveStream]

    struct LiveStream: Codable {
        let id: String
        let snippet: Snippet
        let cdn: CDN

        struct Snippet: Codable {
            let title: String
        }

        struct CDN: Codable {
            let ingestionInfo: IngestionInfo

            struct IngestionInfo: Codable {
                let streamName: String  // This is the stream key
                let ingestionAddress: String  // RTMP URL
            }
        }
    }
}

/// YouTube API v3 error response format
struct YouTubeAPIError: Codable {
    let error: ErrorBody

    struct ErrorBody: Codable {
        let code: Int
        let message: String
        let errors: [ErrorDetail]

        struct ErrorDetail: Codable {
            let message: String
            let domain: String
            let reason: String
        }
    }
}

public struct YouTubeChannelInfo {
    public let id: String
    public let title: String
    public let description: String
    public let thumbnailUrl: String
    public let subscriberCount: Int
    public let videoCount: Int
    public let viewCount: Int
}

struct YouTubeTokenResponse: Codable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
    let scope: String
    let token_type: String
}

struct YouTubeChannelResponse: Codable {
    let items: [Channel]

    struct Channel: Codable {
        let id: String
        let snippet: Snippet
        let statistics: Statistics

        struct Snippet: Codable {
            let title: String
            let description: String
            let thumbnails: Thumbnails

            struct Thumbnails: Codable {
                let `default`: Thumbnail

                struct Thumbnail: Codable {
                    let url: String
                }
            }
        }

        struct Statistics: Codable {
            let viewCount: String
            let subscriberCount: String
            let videoCount: String
        }
    }
}

struct GoogleErrorResponse: Codable {
    let error: String
    let error_description: String?
}

// Update YouTubeError to include Google-specific errors
public enum YouTubeError: LocalizedError {
    case invalidCallback
    case invalidResponse
    case noAccessToken
    case noRefreshToken
    case httpError(statusCode: Int)
    case googleError(String)
    case userCancelled
    case authSessionFailed
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidCallback:
            "Invalid OAuth callback received"
        case .invalidResponse:
            "Invalid response from YouTube"
        case .noAccessToken:
            "No access token available"
        case .noRefreshToken:
            "No refresh token available"
        case let .httpError(statusCode):
            "HTTP error: \(statusCode)"
        case let .googleError(message):
            message
        case .userCancelled:
            "User cancelled the login"
        case .authSessionFailed:
            "Failed to start authentication session"
        case let .unknown(error):
            "Unknown error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Live Chat Response Types

public struct YouTubeLiveChatResult: Sendable {
    public let messages: [YouTubeLiveChatMessage]
    public let nextPageToken: String?
    public let pollingIntervalMs: Int?
}

public struct YouTubeLiveChatResponse: Codable {
    public let nextPageToken: String?
    public let pollingIntervalMillis: Int?
    public let items: [YouTubeLiveChatMessage]
}

public struct YouTubeLiveChatMessage: Codable, Sendable {
    public let id: String
    public let snippet: Snippet
    public let authorDetails: AuthorDetails

    public struct Snippet: Codable, Sendable {
        public let type: String
        public let displayMessage: String
        public let publishedAt: String
        public let superChatDetails: SuperChatDetails?

        public struct SuperChatDetails: Codable, Sendable {
            public let amountMicros: String
            public let currency: String
            public let userComment: String?
        }
    }

    public struct AuthorDetails: Codable, Sendable {
        public let channelId: String
        public let displayName: String
        public let isChatOwner: Bool
        public let isChatModerator: Bool
        public let isChatSponsor: Bool
    }
}
