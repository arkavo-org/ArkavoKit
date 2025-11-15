import Foundation
import Network
import SwiftUI

public actor YouTubeClient: ObservableObject {
    // MARK: - Published Properties

    @MainActor @Published public private(set) var isAuthenticated = false
    @MainActor @Published public private(set) var isLoading = false
    @MainActor @Published public private(set) var error: YouTubeError?
    @MainActor @Published public private(set) var channelInfo: YouTubeChannelInfo?
    @MainActor @Published public var showAuthCodeForm = false

    // MARK: - Private Properties

    private let clientId: String
    private let clientSecret: String
    private let redirectUri: String
    private let keychainServiceBase = "com.arkavo.youtube"

    private enum KeychainKey {
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let tokenExpiration = "token_expiration"
        static let channelId = "channel_id"
    }

    // MARK: - Initialization

    public init(clientId: String, clientSecret: String, redirectUri: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.redirectUri = redirectUri

        Task { @MainActor in
            await loadStoredTokens()
        }
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
            showAuthCodeForm = false
            channelInfo = nil
        }
    }

    // MARK: - Authentication

    public var authURL: URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/youtube.readonly https://www.googleapis.com/auth/youtube.upload"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "state", value: UUID().uuidString),
        ]
        return components.url!
    }

    public func authenticateWithCode(_ code: String) async throws {
        await MainActor.run {
            isLoading = true
            error = nil
        }

        do {
            try await exchangeCodeForTokens(code)
            await fetchChannelInfo()

            await MainActor.run {
                isAuthenticated = true
                showAuthCodeForm = false
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
        let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let parameters = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirectUri,
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
}

// MARK: - Supporting Types

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
    case googleError(String) // New error type
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
        case let .unknown(error):
            "Unknown error: \(error.localizedDescription)"
        }
    }
}
