#if canImport(AppKit)
import AppKit
#endif
import CommonCrypto
import Foundation
import Network
import SwiftUI
import Synchronization

public actor YouTubeClient: ObservableObject {
    // MARK: - Published Properties

    @MainActor @Published public private(set) var isAuthenticated = false
    @MainActor @Published public private(set) var isLoading = false
    @MainActor @Published public private(set) var error: YouTubeError?
    @MainActor @Published public private(set) var channelInfo: YouTubeChannelInfo?
    /// True once Google has reported the grant gone (removed in the Google Account, or
    /// expired) and the stored session was cleared for it. A new sign-in or sign-out resets it.
    @MainActor @Published public private(set) var accessWithdrawn = false

    // MARK: - Private Properties

    private let clientId: String
    private let clientSecret: String
    /// The stored session: the Keychain in the app, a fake in tests.
    private let store: any YouTubeSessionStore
    /// Every request to Google goes through here except the resumable-upload chunks.
    private let send: YouTubeSend
    /// Resumable-upload chunk/probe transport (injectable in tests).
    private let uploadSend: YouTubeSend
    /// Base retry backoff in seconds for resumable uploads (injectable in tests).
    private let uploadRetryBaseSeconds: Double
    private let sessionStoreLock = Mutex<UInt64>(0)
    private var codeVerifier: String?
    var currentRedirectUri: String?
    private var pendingOAuthState: String?
    private var pendingOAuthGeneration: UInt64?
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
        self.init(
            clientId: clientId,
            clientSecret: clientSecret,
            store: KeychainYouTubeSessionStore(service: "com.arkavo.youtube"),
            send: { try await URLSession.shared.data(for: $0) },
        )

        Task { @MainActor in
            await loadStoredTokens()
        }
    }

    /// A client over `store` and `send`. It does not load the stored session; the public
    /// initializer does.
    init(
        clientId: String,
        clientSecret: String,
        store: any YouTubeSessionStore,
        send: @escaping YouTubeSend,
        uploadSend: YouTubeSend? = nil,
        uploadRetryBaseSeconds: Double = 1.0
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.store = store
        self.send = send
        self.uploadSend = uploadSend ?? { try await Self.uploadSession.data(for: $0) }
        self.uploadRetryBaseSeconds = uploadRetryBaseSeconds
    }

    func setRedirectUriForTesting(_ uri: String) {
        currentRedirectUri = uri
    }

    private nonisolated func currentSessionGeneration() -> UInt64 {
        sessionStoreLock.withLock { $0 }
    }

    // MARK: - PKCE Support

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for index in buffer.indices {
                buffer[index] = UInt8.random(in: .min ... .max, using: &rng)
            }
        }
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
        let (generation, accessToken) = sessionStoreLock.withLock { currentGeneration in
            (currentGeneration, store.value(for: KeychainKey.accessToken))
        }

        await MainActor.run {
            guard self.currentSessionGeneration() == generation else { return }
            isAuthenticated = accessToken != nil
        }

        if accessToken != nil, currentSessionGeneration() == generation {
            await fetchChannelInfo(expectedGeneration: generation)
        }
    }

    private nonisolated func saveTokensIfCurrent(
        expectedGeneration: UInt64,
        accessToken: String,
        refreshToken: String,
        expiresIn: Int
    ) -> Bool {
        sessionStoreLock.withLock { currentGeneration in
            guard currentGeneration == expectedGeneration else { return false }
            let expirationDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            store.save(accessToken, for: KeychainKey.accessToken)
            store.save(refreshToken, for: KeychainKey.refreshToken)
            store.save(ISO8601DateFormatter().string(from: expirationDate), for: KeychainKey.tokenExpiration)
            return true
        }
    }

    private nonisolated func saveChannelIDIfCurrent(expectedGeneration: UInt64, channelId: String) -> Bool {
        sessionStoreLock.withLock { currentGeneration in
            guard currentGeneration == expectedGeneration else { return false }
            store.save(channelId, for: KeychainKey.channelId)
            return true
        }
    }

    /// Atomically advances the session generation and removes the stored tokens and channel ID.
    private nonisolated func clearStoredSession() {
        sessionStoreLock.withLock { currentGeneration in
            currentGeneration &+= 1
            store.delete(KeychainKey.accessToken)
            store.delete(KeychainKey.refreshToken)
            store.delete(KeychainKey.tokenExpiration)
            store.delete(KeychainKey.channelId)
        }
    }

    @MainActor
    public func logout() {
        clearStoredSession()

        isAuthenticated = false
        accessWithdrawn = false
        channelInfo = nil
    }

    /// Signs out and withdraws the app's access at Google.
    ///
    /// The stored tokens and channel are removed first, so the sign-out holds
    /// on this Mac whatever Google answers, online or not. The grant is then
    /// revoked with the refresh token, or the access token when there is none.
    /// Google revokes the grant for the whole project, so other devices signed
    /// in to the same Google account with this app lose access too.
    ///
    /// - Returns: what happened to the grant at Google. On `.failed` it may
    ///   still stand there; the person can remove it in their Google Account.
    @MainActor
    @discardableResult
    public func signOut() async -> YouTubeRevocation {
        let (refreshToken, accessToken): (String?, String?) = sessionStoreLock.withLock { currentGeneration in
            currentGeneration &+= 1
            // A sign-in Google answered without a refresh token stores an empty one.
            let refresh = store.value(for: KeychainKey.refreshToken)
                .flatMap { $0.isEmpty ? nil : $0 }
            let access = store.value(for: KeychainKey.accessToken)
            store.delete(KeychainKey.accessToken)
            store.delete(KeychainKey.refreshToken)
            store.delete(KeychainKey.tokenExpiration)
            store.delete(KeychainKey.channelId)
            return (refresh, access)
        }

        isAuthenticated = false
        accessWithdrawn = false
        channelInfo = nil

        return await Self.revoke(token: refreshToken ?? accessToken, isRefreshToken: refreshToken != nil, send: send)
    }

    /// Google's OAuth 2.0 revocation request for one token. The token goes in
    /// the form body, never in the URL.
    static func revocationRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Unreserved characters only: `+`, `/` and `=` occur in tokens and mean something in a form body.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = token.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        request.httpBody = Data("token=\(encoded)".utf8)
        return request
    }

    /// Revokes `token` at Google. Revoking either token of a grant ends the grant.
    ///
    /// - Parameter isRefreshToken: a refresh token Google calls invalid means the grant is
    ///   gone. An access token it calls invalid may only have expired, with the grant still
    ///   standing, so that is `.failed`.
    static func revoke(
        token: String?,
        isRefreshToken: Bool,
        send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async -> YouTubeRevocation {
        guard let token, !token.isEmpty else { return .nothingToRevoke }
        guard let (data, response) = try? await send(revocationRequest(token: token)),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .failed }
        if status == 200 { return .revoked }
        if status == 400, isRefreshToken,
           let reply = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data),
           reply.error == "invalid_token"
        {
            return .nothingToRevoke
        }
        return .failed
    }

    // MARK: - Authentication

    private func buildAuthURL(redirectUri: String, state: String, attemptGeneration: UInt64? = nil) -> URL {
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        pendingOAuthState = state
        pendingOAuthGeneration = attemptGeneration ?? currentSessionGeneration()
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
        let attemptGeneration = currentSessionGeneration()
        await MainActor.run {
            isLoading = true
            error = nil
        }

        // Clean up any existing server
        callbackServer?.stop()
        let server = OAuthCallbackServer()
        callbackServer = server

        defer {
            server.stop()
            if callbackServer === server {
                callbackServer = nil
            }
        }

        do {
            let state = UUID().uuidString

            // Start the listener and wait deterministically until it is bound to a port.
            _ = try server.startListening(state: state)

            // Store the redirect URI for token exchange
            let redirectUri = server.redirectUri
            currentRedirectUri = redirectUri

            // Build auth URL with the dynamic localhost redirect
            let authURL = buildAuthURL(redirectUri: redirectUri, state: state, attemptGeneration: attemptGeneration)

            // Open browser for authentication. If it doesn't open, the wait below times out.
            await MainActor.run {
                _ = NSWorkspace.shared.open(authURL)
            }

            // Wait for the callback with structured task cancellation support
            let code = try await server.waitForCallback(timeout: 300)

            guard currentSessionGeneration() == attemptGeneration else {
                await MainActor.run {
                    isLoading = false
                }
                throw CancellationError()
            }

            try await completeSignIn(code: code, redirectUri: redirectUri, expectedGeneration: attemptGeneration)
            await MainActor.run {
                isLoading = false
            }

        } catch let oauthError as OAuthCallbackServer.OAuthError {
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
            let youtubeError = error as? YouTubeError ?? .unknown(error)
            await MainActor.run {
                self.error = youtubeError
                isLoading = false
            }
            throw error
        }
    }
    #endif

    public func handleCallback(_ url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw YouTubeError.invalidCallback
        }

        let queryItems = components.queryItems ?? []
        guard let expectedState = pendingOAuthState,
              let returnedState = queryItems.first(where: { $0.name == "state" })?.value,
              returnedState == expectedState
        else {
            throw YouTubeError.invalidCallback
        }
        let attemptGeneration = pendingOAuthGeneration ?? currentSessionGeneration()
        pendingOAuthState = nil
        pendingOAuthGeneration = nil

        if let oauthError = queryItems.first(where: { $0.name == "error" })?.value {
            let description = queryItems.first(where: { $0.name == "error_description" })?.value ?? oauthError
            throw YouTubeError.googleError(description)
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            throw YouTubeError.invalidCallback
        }

        await MainActor.run {
            isLoading = true
            error = nil
        }

        do {
            guard let redirectUri = currentRedirectUri else {
                throw YouTubeError.invalidCallback
            }
            try await completeSignIn(code: code, redirectUri: redirectUri, expectedGeneration: attemptGeneration)
            await MainActor.run {
                isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error as? YouTubeError ?? .unknown(error)
                isLoading = false
            }
            throw error
        }
    }

    /// Stores the tokens for `code`, marks the person signed in, then loads their channel.
    /// Signed in comes first, so a withdrawn grant the channel fetch finds is the state that remains.
    func completeSignIn(code: String, redirectUri: String, expectedGeneration: UInt64? = nil) async throws {
        let generation = expectedGeneration ?? currentSessionGeneration()
        let saved = try await exchangeCodeForTokens(code, redirectUri: redirectUri, expectedGeneration: generation)
        guard saved, currentSessionGeneration() == generation else { return }
        await MainActor.run {
            guard self.currentSessionGeneration() == generation else { return }
            isAuthenticated = true
            accessWithdrawn = false
        }
        guard currentSessionGeneration() == generation else { return }
        await fetchChannelInfo(expectedGeneration: generation)
    }

    // Make exchangeCodeForTokens public so it can be used directly with authorization code
    public func exchangeCodeForTokens(_ code: String) async throws {
        guard let redirectUri = currentRedirectUri else {
            throw YouTubeError.invalidCallback
        }
        let generation = pendingOAuthGeneration ?? currentSessionGeneration()
        let saved = try await exchangeCodeForTokens(code, redirectUri: redirectUri, expectedGeneration: generation)
        guard saved else {
            throw CancellationError()
        }
    }

    private func exchangeCodeForTokens(
        _ code: String,
        redirectUri: String,
        expectedGeneration: UInt64
    ) async throws -> Bool {
        guard currentSessionGeneration() == expectedGeneration else {
            return false
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

        let (data, response) = try await send(request)

        guard currentSessionGeneration() == expectedGeneration else {
            return false
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let tokenResponse = try JSONDecoder().decode(YouTubeTokenResponse.self, from: data)
            return saveTokensIfCurrent(
                expectedGeneration: expectedGeneration,
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

    /// Asks Google for a new access token with the stored refresh token.
    ///
    /// - Returns: the new access token, now stored; nil when the session was signed out or
    ///   replaced while the request was out, so the answer was dropped.
    @discardableResult
    private func refreshAccessToken() async throws -> String? {
        // Atomically capture session generation and stored refresh token.
        let (generation, storedRefreshToken) = sessionStoreLock.withLock { currentGeneration in
            (currentGeneration, store.value(for: KeychainKey.refreshToken))
        }
        // A sign-in Google answered without a refresh token stores an empty one.
        guard let refreshToken = storedRefreshToken, !refreshToken.isEmpty else {
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

        let (data, response) = try await send(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }

        // The actor may have signed out (revoking this very token) or signed in again while the
        // request was out; its answer then speaks for a grant no longer stored, and is dropped.
        if httpResponse.statusCode == 200 {
            let tokenResponse = try JSONDecoder().decode(YouTubeTokenResponse.self, from: data)
            let saved = sessionStoreLock.withLock { currentGeneration -> Bool in
                guard currentGeneration == generation,
                      store.value(for: KeychainKey.refreshToken) == refreshToken
                else { return false }
                let expirationDate = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in))
                store.save(tokenResponse.access_token, for: KeychainKey.accessToken)
                store.save(refreshToken, for: KeychainKey.refreshToken)
                store.save(ISO8601DateFormatter().string(from: expirationDate), for: KeychainKey.tokenExpiration)
                return true
            }
            return saved ? tokenResponse.access_token : nil
        } else if Self.grantWithdrawn(status: httpResponse.statusCode, data: data) {
            let cleared = sessionStoreLock.withLock { currentGeneration -> Bool in
                guard currentGeneration == generation,
                      store.value(for: KeychainKey.refreshToken) == refreshToken
                else { return false }
                currentGeneration &+= 1
                store.delete(KeychainKey.accessToken)
                store.delete(KeychainKey.refreshToken)
                store.delete(KeychainKey.tokenExpiration)
                store.delete(KeychainKey.channelId)
                return true
            }
            if cleared {
                await MainActor.run {
                    isAuthenticated = false
                    channelInfo = nil
                    accessWithdrawn = true
                }
                throw YouTubeError.accessWithdrawn
            }
            throw YouTubeError.httpError(statusCode: httpResponse.statusCode)
        } else {
            throw YouTubeError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    /// Whether a token-refresh answer says the grant is gone: Google's 400 `invalid_grant`,
    /// which it sends when the person removed the app's access or the refresh token expired.
    /// Any other answer may be a passing failure and ends nothing.
    static func grantWithdrawn(status: Int, data: Data) -> Bool {
        guard status == 400,
              let reply = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data)
        else { return false }
        return reply.error == "invalid_grant"
    }

    /// Checks with Google that the stored grant still stands, by refreshing the access token.
    /// Call it from time to time while signed in (for example when the app becomes active),
    /// so access removed in the Google Account is noticed without waiting for the next request.
    ///
    /// - Returns: false when Google reported the grant gone; the stored tokens and channel are
    ///   then already removed and `accessWithdrawn` is true. True otherwise, including when
    ///   nothing is stored, no refresh token is stored, or Google could not be reached.
    @discardableResult
    public func verifyAccess() async -> Bool {
        let refreshToken = store.value(for: KeychainKey.refreshToken)
        guard let refreshToken, !refreshToken.isEmpty else { return true }
        do {
            try await refreshAccessToken()
            return true
        } catch YouTubeError.accessWithdrawn {
            return false
        } catch {
            return true
        }
    }

    // MARK: - API Methods

    private func getValidAccessToken() async throws -> String {
        if let expirationString = store.value(for: KeychainKey.tokenExpiration),
           let expirationDate = ISO8601DateFormatter().date(from: expirationString),
           let accessToken = store.value(for: KeychainKey.accessToken),
           expirationDate > Date().addingTimeInterval(60)
        {
            return accessToken
        }

        // Token expired or will expire soon, try to refresh
        guard let newAccessToken = try await refreshAccessToken() else {
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

    /// Sends a request built by `makeAuthorizedRequest`.
    ///
    /// When Google refuses the access token (401), this asks whether the grant still stands by
    /// refreshing it. A withdrawn grant ends the stored session and throws `accessWithdrawn`.
    /// A grant that refreshes gets the request sent once more, unchanged but for the new token;
    /// Google refuses a 401 before acting on the request, so this is safe for POSTs too. Any
    /// other outcome of the check says nothing about the grant, and the 401 is returned for the
    /// caller to report.
    private func sendAuthorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, http) = try await sendHTTP(request)
        guard http.statusCode == 401 else { return (data, http) }

        let refreshed: String?
        do {
            refreshed = try await refreshAccessToken()
        } catch YouTubeError.accessWithdrawn {
            throw YouTubeError.accessWithdrawn
        } catch {
            return (data, http)
        }
        // Nil: signed out or in again meanwhile, so the request's session is gone.
        guard let refreshed else { return (data, http) }

        var retry = request
        retry.setValue("Bearer \(refreshed)", forHTTPHeaderField: "Authorization")
        return try await sendHTTP(retry)
    }

    private func sendHTTP(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }
        return (data, http)
    }

    func fetchChannelInfo(expectedGeneration: UInt64? = nil) async {
        let generation = expectedGeneration ?? currentSessionGeneration()
        do {
            guard currentSessionGeneration() == generation else { return }
            let url = URL(string: "https://www.googleapis.com/youtube/v3/channels?part=snippet,statistics&mine=true")!
            let request = try await makeAuthorizedRequest(url: url)
            let (data, httpResponse) = try await sendAuthorized(request)

            guard currentSessionGeneration() == generation else { return }

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

                    // Atomically save channel ID only if session generation is still current
                    guard saveChannelIDIfCurrent(expectedGeneration: generation, channelId: channel.id) else {
                        return
                    }

                    await MainActor.run {
                        guard self.currentSessionGeneration() == generation else { return }
                        self.channelInfo = info
                    }
                }
            } else {
                throw YouTubeError.httpError(statusCode: httpResponse.statusCode)
            }
        } catch {
            await MainActor.run {
                guard self.currentSessionGeneration() == generation else { return }
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
        let (data, httpResponse) = try await sendAuthorized(request)

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

        let (data, httpResponse) = try await sendAuthorized(request)

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

    private static func makeYouTubeAPIURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            throw YouTubeError.invalidResponse
        }
        return url
    }

    /// Creates a broadcast, binds it to a stream, and returns the broadcast ID.
    /// Call this before starting RTMP streaming to YouTube.
    /// - Parameter privacyStatus: One of "public", "unlisted", "private". Defaults to "public" for backward compatibility.
    public func createAndBindBroadcast(title: String, privacyStatus: String = "public") async throws -> String {
        let allowedPrivacy: Set<String> = ["public", "unlisted", "private"]
        // Fail closed to "private" if caller passes an unrecognized privacy status.
        let validatedPrivacy = allowedPrivacy.contains(privacyStatus) ? privacyStatus : "private"
        // 1. Get or create a live stream
        let url = URL(string: "https://www.googleapis.com/youtube/v3/liveStreams?part=cdn,snippet&mine=true")!
        let listRequest = try await makeAuthorizedRequest(url: url)
        let (listData, listHttp) = try await sendAuthorized(listRequest)

        guard listHttp.statusCode == 200 else {
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

        let (broadcastData, broadcastHttp) = try await sendAuthorized(broadcastRequest)
        guard (200...201).contains(broadcastHttp.statusCode) else {
            if let errorResponse = try? JSONDecoder().decode(GoogleErrorResponse.self, from: broadcastData) {
                throw YouTubeError.googleError("Broadcast creation failed: \(errorResponse.error_description ?? errorResponse.error)")
            }
            throw YouTubeError.googleError("Broadcast creation failed (HTTP \(broadcastHttp.statusCode))")
        }

        let broadcast = try JSONDecoder().decode(YouTubeBroadcastResponse.self, from: broadcastData)
        let broadcastId = broadcast.id

        // 3. Bind the stream to the broadcast
        let bindURL = try Self.makeYouTubeAPIURL(
            path: "/youtube/v3/liveBroadcasts/bind",
            queryItems: [
                URLQueryItem(name: "id", value: broadcastId),
                URLQueryItem(name: "part", value: "id,contentDetails"),
                URLQueryItem(name: "streamId", value: streamId),
            ]
        )
        var bindRequest = try await makeAuthorizedRequest(url: bindURL)
        bindRequest.httpMethod = "POST"
        bindRequest.httpBody = Data() // empty body required

        let (_, bindHttp) = try await sendAuthorized(bindRequest)
        guard bindHttp.statusCode == 200 else {
            throw YouTubeError.googleError("Failed to bind stream to broadcast")
        }

        return broadcastId
    }

    /// Check the current lifecycle status of a broadcast
    public func getBroadcastStatus(broadcastId: String) async throws -> String {
        let url = try Self.makeYouTubeAPIURL(
            path: "/youtube/v3/liveBroadcasts",
            queryItems: [
                URLQueryItem(name: "id", value: broadcastId),
                URLQueryItem(name: "part", value: "status"),
            ]
        )
        let request = try await makeAuthorizedRequest(url: url)
        let (data, httpResponse) = try await sendAuthorized(request)

        guard httpResponse.statusCode == 200 else {
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
        }

        // Poll until testing or live (YouTube transitions asynchronously through "testStarting").
        var afterTesting = try await getBroadcastStatus(broadcastId: broadcastId)
        for i in 1...12 {
            if afterTesting == "testing" || afterTesting == "live" {
                break
            }
            if afterTesting != "testStarting" && afterTesting != "ready" {
                throw YouTubeError.googleError("Broadcast entered unexpected state '\(afterTesting)' before going live.")
            }
            if i == 12 {
                throw YouTubeError.googleError("Broadcast remained in '\(afterTesting)' state and did not become ready for live transition.")
            }
            try await Task.sleep(for: .seconds(5))
            afterTesting = try await getBroadcastStatus(broadcastId: broadcastId)
        }

        // Transition: testing → live (skip if already live)
        if afterTesting == "testing" {
            try await transitionBroadcast(broadcastId: broadcastId, to: "live")
        } else if afterTesting != "live" {
            throw YouTubeError.googleError("Broadcast did not reach 'testing' or 'live' state (current: '\(afterTesting)').")
        }
    }

    /// Transition a broadcast to a specific status
    private func transitionBroadcast(broadcastId: String, to status: String) async throws {
        let url = try Self.makeYouTubeAPIURL(
            path: "/youtube/v3/liveBroadcasts/transition",
            queryItems: [
                URLQueryItem(name: "broadcastStatus", value: status),
                URLQueryItem(name: "id", value: broadcastId),
                URLQueryItem(name: "part", value: "status"),
            ]
        )
        var request = try await makeAuthorizedRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()

        let (data, httpResponse) = try await sendAuthorized(request)

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
    ///
    /// Best-effort: an answer other than 200 is ignored. It throws only when no request could
    /// be made or sent, or when Google reports the grant withdrawn (`accessWithdrawn`).
    public func endBroadcast(broadcastId: String) async throws {
        let url = try Self.makeYouTubeAPIURL(
            path: "/youtube/v3/liveBroadcasts/transition",
            queryItems: [
                URLQueryItem(name: "broadcastStatus", value: "complete"),
                URLQueryItem(name: "id", value: broadcastId),
                URLQueryItem(name: "part", value: "status"),
            ]
        )
        var request = try await makeAuthorizedRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()

        _ = try await sendAuthorized(request)
    }

    /// Fetches the liveChatId for a broadcast.
    ///
    /// - Returns: nil when YouTube answers other than 200. Throws `accessWithdrawn` when Google
    ///   reports the grant withdrawn.
    public func getLiveChatId(broadcastId: String) async throws -> String? {
        let url = try Self.makeYouTubeAPIURL(
            path: "/youtube/v3/liveBroadcasts",
            queryItems: [
                URLQueryItem(name: "id", value: broadcastId),
                URLQueryItem(name: "part", value: "snippet"),
            ]
        )
        let request = try await makeAuthorizedRequest(url: url)
        let (data, httpResponse) = try await sendAuthorized(request)

        guard httpResponse.statusCode == 200 else {
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
        let data = try await fetchLiveChatData(liveChatId: liveChatId, pageToken: pageToken)
        let chatResponse = try JSONDecoder().decode(YouTubeLiveChatResponse.self, from: data)
        return YouTubeLiveChatResult(
            messages: chatResponse.items,
            nextPageToken: chatResponse.nextPageToken,
            pollingIntervalMs: chatResponse.pollingIntervalMillis
        )
    }

    /// Fetches the unmodified live-chat page, including moderation events without display content.
    /// Consumers can decode optional service fields while preserving the client's OAuth refresh.
    public func fetchLiveChatData(liveChatId: String, pageToken: String?) async throws -> Data {
        var urlComponents = URLComponents(string: "https://www.googleapis.com/youtube/v3/liveChat/messages")!
        urlComponents.queryItems = [
            URLQueryItem(name: "liveChatId", value: liveChatId),
            URLQueryItem(name: "part", value: "snippet,authorDetails"),
        ]
        if let pageToken = pageToken {
            urlComponents.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        let request = try await makeAuthorizedRequest(url: urlComponents.url!)
        let (data, httpResponse) = try await sendAuthorized(request)

        guard httpResponse.statusCode == 200 else {
            throw YouTubeError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
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

        let (data, httpResponse) = try await sendAuthorized(request)
        guard (200...201).contains(httpResponse.statusCode) else {
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

        let (data, http) = try await sendAuthorized(request)
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
    /// or nil if the header is missing/unparseable/out-of-range.
    static func nextOffsetFromRangeHeader(_ header: String?) -> Int64? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              header.hasPrefix("bytes=0-")
        else { return nil }
        let endStr = header.dropFirst("bytes=0-".count)
        guard !endStr.isEmpty,
              let serverEnd = Int64(endStr),
              serverEnd >= 0,
              serverEnd < Int64.max
        else { return nil }
        return serverEnd + 1
    }

    func uploadResumableChunks(
        to uploadURL: URL,
        fileURL: URL,
        totalSize: Int64,
        mimeType: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var stalled308Count = 0
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
                } catch is URLError where attempt < Self.uploadMaxAttempts {
                    // Transient network issue (timeout, lost connection, etc.).
                    let delaySeconds = uploadRetryBaseSeconds * Double(1 << (attempt - 1))  // 1, 2, 4, 8, 16
                    if delaySeconds > 0 {
                        try await Task.sleep(for: .seconds(delaySeconds))
                    }
                    // Re-query the server for the byte offset it actually has;
                    // it may have committed bytes before the error reached us.
                    if let probed = try? await probeUploadOffset(uploadURL: uploadURL, totalSize: totalSize) {
                        if let videoId = probed.completedVideoId {
                            onProgress?(1.0)
                            return videoId
                        }
                        let probedOffset = probed.nextOffset ?? 0
                        if probedOffset >= 0,
                           probedOffset <= totalSize,
                           probedOffset != offset
                        {
                            offset = probedOffset
                            stalled308Count = 0
                            onProgress?(Double(offset) / Double(totalSize))
                            break chunkAttempt
                        }
                    }
                    continue chunkAttempt
                }

                switch result {
                case .completed(let videoId):
                    onProgress?(1.0)
                    return videoId

                case .resumeIncomplete(let serverNextOffset):
                    // Per Google's resumable upload spec, a 308 without a Range header means 0 bytes committed.
                    let nextOffset = serverNextOffset ?? 0
                    guard nextOffset >= 0, nextOffset <= totalSize else {
                        throw YouTubeError.invalidResponse
                    }
                    if nextOffset <= offset {
                        stalled308Count += 1
                        guard stalled308Count < Self.uploadMaxAttempts else {
                            throw YouTubeError.googleError("Upload stalled: server did not advance byte offset after \(stalled308Count) attempts")
                        }
                        let delaySeconds = uploadRetryBaseSeconds * Double(1 << (stalled308Count - 1))
                        if delaySeconds > 0 {
                            try await Task.sleep(for: .seconds(delaySeconds))
                        }
                    } else {
                        stalled308Count = 0
                    }
                    offset = nextOffset
                    onProgress?(Double(offset) / Double(totalSize))
                    break chunkAttempt

                case .transient(let statusCode):
                    guard attempt < Self.uploadMaxAttempts else {
                        throw YouTubeError.googleError("Upload chunk failed after \(attempt) attempts (HTTP \(statusCode))")
                    }
                    let delaySeconds = uploadRetryBaseSeconds * Double(1 << (attempt - 1))
                    if delaySeconds > 0 {
                        try await Task.sleep(for: .seconds(delaySeconds))
                    }
                    if let probed = try? await probeUploadOffset(uploadURL: uploadURL, totalSize: totalSize) {
                        if let videoId = probed.completedVideoId {
                            onProgress?(1.0)
                            return videoId
                        }
                        let probedOffset = probed.nextOffset ?? 0
                        if probedOffset >= 0,
                           probedOffset <= totalSize,
                           probedOffset != offset
                        {
                            offset = probedOffset
                            stalled308Count = 0
                            onProgress?(Double(offset) / Double(totalSize))
                            break chunkAttempt
                        }
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

        let (data, response) = try await uploadSend(request)
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

        let (data, response) = try await uploadSend(request)
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

/// Sends one request to Google.
typealias YouTubeSend = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Where `YouTubeClient` keeps the session's tokens and channel ID, by account name.
protocol YouTubeSessionStore: Sendable {
    func value(for account: String) -> String?
    func save(_ value: String, for account: String)
    func delete(_ account: String)
}

/// The app's session store: generic passwords in the Keychain under one service.
struct KeychainYouTubeSessionStore: YouTubeSessionStore {
    let service: String

    func value(for account: String) -> String? {
        KeychainManager.getValue(service: service, account: account)
    }

    func save(_ value: String, for account: String) {
        KeychainManager.save(value: value, service: service, account: account)
    }

    func delete(_ account: String) {
        try? KeychainManager.delete(service: service, account: account)
    }
}

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

            private enum CodingKeys: String, CodingKey {
                case viewCount
                case subscriberCount
                case videoCount
            }

            init(viewCount: String, subscriberCount: String = "0", videoCount: String) {
                self.viewCount = viewCount
                self.subscriberCount = subscriberCount
                self.videoCount = videoCount
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                viewCount = try container.decodeIfPresent(String.self, forKey: .viewCount) ?? "0"
                subscriberCount = try container.decodeIfPresent(String.self, forKey: .subscriberCount) ?? "0"
                videoCount = try container.decodeIfPresent(String.self, forKey: .videoCount) ?? "0"
            }
        }
    }
}

struct GoogleErrorResponse: Codable {
    let error: String
    let error_description: String?
}

/// What `YouTubeClient.signOut()` did about the grant at Google.
public enum YouTubeRevocation: Sendable, Equatable {
    /// Google revoked the grant.
    case revoked
    /// No token was stored, or Google no longer honors the stored refresh token.
    case nothingToRevoke
    /// Google could not be reached or refused, or only an expired access token was
    /// stored; the grant may still stand.
    case failed
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
    /// Google reported the grant gone; the stored session has been cleared.
    case accessWithdrawn
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
        case .accessWithdrawn:
            "YouTube access was removed in your Google Account. Sign in again to reconnect."
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

        private enum CodingKeys: String, CodingKey {
            case type
            case displayMessage
            case publishedAt
            case superChatDetails
        }

        public struct SuperChatDetails: Codable, Sendable {
            public let amountMicros: String
            public let currency: String
            public let userComment: String?
        }

        public init(
            type: String,
            displayMessage: String,
            publishedAt: String,
            superChatDetails: SuperChatDetails? = nil
        ) {
            self.type = type
            self.displayMessage = displayMessage
            self.publishedAt = publishedAt
            self.superChatDetails = superChatDetails
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            displayMessage = try container.decodeIfPresent(String.self, forKey: .displayMessage) ?? ""
            publishedAt = try container.decode(String.self, forKey: .publishedAt)
            superChatDetails = try container.decodeIfPresent(SuperChatDetails.self, forKey: .superChatDetails)
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
