import Foundation
import SwiftUI

public class RedditClient: ObservableObject {
    // MARK: - Published Properties

    @MainActor @Published public var isAuthenticated = false
    @MainActor @Published public var isLoading = false
    @MainActor @Published public var showingWebView = false
    @MainActor @Published public var username = ""
    @MainActor @Published public var error: RedditError?

    // MARK: - Private Properties

    private let clientId: String
    private let redirectUri: String
    @MainActor private var accessToken: String?
    @MainActor private var refreshToken: String?
    @MainActor private var tokenExpirationDate: Date?
    @MainActor private var pendingOAuthState: String?
    @MainActor private var sessionGeneration: UInt64 = 0
    @MainActor private var activeRefreshTask: Task<Void, Error>?

    // MARK: - Keychain Constants

    private let keychainServiceBase = "com.arkavo.reddit"
    private enum KeychainKey {
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let tokenExpiration = "token_expiration"
    }

    // MARK: - Initialization

    public init(clientId: String, redirectUri: String = "arkavocreator://oauth/reddit") {
        self.clientId = clientId
        self.redirectUri = redirectUri
    }

    // MARK: - Token Management

    @MainActor
    public func loadStoredTokens() {
        accessToken = KeychainManager.getValue(
            service: keychainServiceBase,
            account: KeychainKey.accessToken,
        )
        refreshToken = KeychainManager.getValue(
            service: keychainServiceBase,
            account: KeychainKey.refreshToken,
        )

        if let expirationString = KeychainManager.getValue(
            service: keychainServiceBase,
            account: KeychainKey.tokenExpiration,
        ) {
            tokenExpirationDate = ISO8601DateFormatter().date(from: expirationString)
        }

        isAuthenticated = accessToken != nil

        if isAuthenticated {
            let generation = sessionGeneration
            Task { @MainActor in
                await fetchUsername(expectedGeneration: generation)
            }
        }
    }

    // MARK: - Authentication URL

    @MainActor
    public var authURL: URL {
        let state: String
        if let existing = pendingOAuthState {
            state = existing
        } else {
            state = UUID().uuidString
            pendingOAuthState = state
        }

        var components = URLComponents(string: "https://www.reddit.com/api/v1/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "duration", value: "permanent"),
            URLQueryItem(name: "scope", value: "identity read submit"),
        ]
        return components.url!
    }

    // MARK: - Public Methods

    @MainActor
    public func startOAuth() {
        showingWebView = true
    }

    @MainActor
    public func handleCallback(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            handleError(RedditError.invalidCallback)
            return
        }

        let queryItems = components.queryItems ?? []
        guard let expectedState = pendingOAuthState,
              let returnedState = queryItems.first(where: { $0.name == "state" })?.value,
              returnedState == expectedState
        else {
            handleError(RedditError.invalidCallback)
            return
        }
        pendingOAuthState = nil
        showingWebView = false

        if queryItems.contains(where: { $0.name == "error" }) {
            handleError(RedditError.invalidCallback)
            return
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            handleError(RedditError.invalidCallback)
            return
        }

        let attemptGeneration = sessionGeneration
        Task { @MainActor in
            await exchangeCodeForToken(code, expectedGeneration: attemptGeneration)
        }
    }

    @MainActor
    private func saveTokens(accessToken: String, refreshToken: String?, expirationDate: Date) {
        self.accessToken = accessToken
        if let refreshToken, !refreshToken.isEmpty {
            self.refreshToken = refreshToken
            KeychainManager.save(
                value: refreshToken,
                service: keychainServiceBase,
                account: KeychainKey.refreshToken,
            )
        }
        tokenExpirationDate = expirationDate

        // Save to Keychain
        KeychainManager.save(
            value: accessToken,
            service: keychainServiceBase,
            account: KeychainKey.accessToken,
        )

        KeychainManager.save(
            value: ISO8601DateFormatter().string(from: expirationDate),
            service: keychainServiceBase,
            account: KeychainKey.tokenExpiration,
        )
    }

    @MainActor
    public func logout() {
        sessionGeneration &+= 1
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        pendingOAuthState = nil

        // Clear Keychain
        try? KeychainManager.delete(service: keychainServiceBase, account: KeychainKey.accessToken)
        try? KeychainManager.delete(service: keychainServiceBase, account: KeychainKey.refreshToken)
        try? KeychainManager.delete(service: keychainServiceBase, account: KeychainKey.tokenExpiration)
        // Clear memory
        accessToken = nil
        refreshToken = nil
        tokenExpirationDate = nil
        isAuthenticated = false
        username = ""
    }

    // MARK: - API Methods

    @MainActor
    public func fetchUserInfo() async throws -> RedditUserInfo {
        _ = try await getValidAccessToken()
        let request = try makeAuthorizedRequest(url: URL(string: "https://oauth.reddit.com/api/v1/me")!)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RedditError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            return try JSONDecoder().decode(RedditUserInfo.self, from: data)
        } else {
            throw RedditError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    @MainActor
    private func exchangeCodeForToken(_ code: String, expectedGeneration: UInt64) async {
        guard sessionGeneration == expectedGeneration else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let tokenURL = URL(string: "https://www.reddit.com/api/v1/access_token")!
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"

            let authString = "\(clientId):"
            let authData = Data(authString.utf8).base64EncodedString()
            request.setValue("Basic \(authData)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let parameters = [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectUri,
            ]

            request.httpBody = parameters.percentEncoded()

            let (data, response) = try await URLSession.shared.data(for: request)

            guard sessionGeneration == expectedGeneration else { return }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RedditError.invalidResponse
            }

            if httpResponse.statusCode == 200 {
                let tokenResponse = try JSONDecoder().decode(RedditTokenResponse.self, from: data)
                guard sessionGeneration == expectedGeneration else { return }
                handleTokenResponse(tokenResponse, fetchUser: true, expectedGeneration: expectedGeneration)
            } else {
                throw RedditError.httpError(statusCode: httpResponse.statusCode)
            }
        } catch {
            if sessionGeneration == expectedGeneration {
                handleError(error)
            }
        }
    }

    @MainActor
    public func refreshAccessToken() async throws {
        if let existingTask = activeRefreshTask {
            return try await existingTask.value
        }

        let generation = sessionGeneration
        guard let currentRefreshToken = refreshToken, !currentRefreshToken.isEmpty else {
            throw RedditError.noRefreshToken
        }

        let task = Task<Void, Error> { @MainActor in
            defer { self.activeRefreshTask = nil }

            let tokenURL = URL(string: "https://www.reddit.com/api/v1/access_token")!
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"

            let authString = "\(self.clientId):"
            let authData = Data(authString.utf8).base64EncodedString()
            request.setValue("Basic \(authData)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let parameters = [
                "grant_type": "refresh_token",
                "refresh_token": currentRefreshToken,
            ]

            request.httpBody = parameters.percentEncoded()

            let (data, response) = try await URLSession.shared.data(for: request)

            guard self.sessionGeneration == generation else {
                throw CancellationError()
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RedditError.invalidResponse
            }

            if httpResponse.statusCode == 200 {
                let tokenResponse = try JSONDecoder().decode(RedditTokenResponse.self, from: data)
                guard self.sessionGeneration == generation else {
                    throw CancellationError()
                }
                self.handleTokenResponse(tokenResponse, fetchUser: false, expectedGeneration: generation)
            } else {
                throw RedditError.httpError(statusCode: httpResponse.statusCode)
            }
        }

        activeRefreshTask = task
        return try await task.value
    }

    @MainActor
    private func handleTokenResponse(_ response: RedditTokenResponse, fetchUser: Bool, expectedGeneration: UInt64) {
        guard sessionGeneration == expectedGeneration else { return }
        let expirationDate = Date().addingTimeInterval(TimeInterval(response.expires_in))
        saveTokens(
            accessToken: response.access_token,
            refreshToken: response.refresh_token,
            expirationDate: expirationDate,
        )

        isAuthenticated = true
        if fetchUser {
            Task { @MainActor in
                await fetchUsername(expectedGeneration: expectedGeneration)
            }
        }
    }

    @MainActor
    private func getValidAccessToken() async throws -> String {
        if let tokenExpirationDate,
           let accessToken,
           tokenExpirationDate > Date().addingTimeInterval(60)
        {
            return accessToken
        }

        // Token expired or will expire soon, try to refresh
        if refreshToken != nil {
            do {
                try await refreshAccessToken()
                if let newAccessToken = accessToken {
                    return newAccessToken
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let redditError as RedditError {
                switch redditError {
                case .noRefreshToken, .httpError(statusCode: 400), .httpError(statusCode: 401):
                    // Permanent auth failure: clear tokens and require re-authentication
                    logout()
                    throw RedditError.noAccessToken
                default:
                    // Transient error (e.g., 5xx): keep stored session intact
                    throw redditError
                }
            } catch {
                // Transient transport error (e.g., offline/timeout): keep stored session intact
                throw error
            }
        }

        throw RedditError.noAccessToken
    }

    @MainActor
    private func makeAuthorizedRequest(url: URL) throws -> URLRequest {
        guard let accessToken else {
            throw RedditError.noAccessToken
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    @MainActor
    private func fetchUsername(expectedGeneration: UInt64) async {
        do {
            let userInfo = try await fetchUserInfo()
            guard sessionGeneration == expectedGeneration else { return }
            username = userInfo.name
        } catch is CancellationError {
            return
        } catch {
            if sessionGeneration == expectedGeneration {
                handleError(error)
            }
        }
    }

    @MainActor
    private func handleError(_ error: Error) {
        if let redditError = error as? RedditError {
            self.error = redditError
        } else {
            self.error = .unknown(error)
        }
    }
}

// MARK: - Supporting Types

struct RedditTokenResponse: Codable {
    let access_token: String
    let token_type: String
    let expires_in: Int
    let refresh_token: String?
    let scope: String
}

public struct RedditUserInfo: Codable, Sendable {
    public let id: String
    public let name: String
    public let created: Double
    public let link_karma: Int
    public let comment_karma: Int
    public let has_verified_email: Bool
}

public enum RedditError: LocalizedError {
    case invalidCallback
    case invalidResponse
    case noAccessToken
    case noRefreshToken
    case httpError(statusCode: Int)
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidCallback:
            "Invalid OAuth callback received"
        case .invalidResponse:
            "Invalid response from Reddit"
        case .noAccessToken:
            "No access token available"
        case .noRefreshToken:
            "No refresh token available"
        case let .httpError(statusCode):
            "HTTP error: \(statusCode)"
        case let .unknown(error):
            "Unknown error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Extensions

extension [String: String] {
    /// RFC 3986 `application/x-www-form-urlencoded` serialization.
    /// Encodes all characters outside unreserved `A-Za-z0-9-._~` (including `+`, `&`, `=`, `/`, `?`, spaces).
    func percentEncoded() -> Data {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }
}
