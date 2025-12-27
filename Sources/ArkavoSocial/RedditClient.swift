import Foundation
import SwiftUI

public class RedditClient: ObservableObject {
    // MARK: - Published Properties

    @Published public var isAuthenticated = false
    @Published public var isLoading = false
    @Published public var showingWebView = false
    @Published public var username = ""
    @Published public var error: RedditError?

    // MARK: - Private Properties

    private let clientId: String
    private let redirectUri: String
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpirationDate: Date?

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
        // TODO: handle call. fix concurrency issue
//        NotificationCenter.default.addObserver(
//            forName: Notification.Name("RedditOAuthCallback"),
//            object: nil,
//            queue: .main
//        ) { [weak self] notification in
//            guard let url = notification.userInfo?["url"] as? URL else { return }
//            self?.handleCallback(url)
//        }
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
            Task {
                await fetchUsername()
            }
        }
    }

    // MARK: - Authentication URL

    public var authURL: URL {
        var components = URLComponents(string: "https://www.reddit.com/api/v1/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: UUID().uuidString),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "duration", value: "permanent"),
            URLQueryItem(name: "scope", value: "identity read submit"),
        ]
        return components.url!
    }

    // MARK: - Public Methods

    public func startOAuth() {
        showingWebView = true
    }

    @MainActor
    public func handleCallback(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            handleError(RedditError.invalidCallback)
            return
        }

        Task { @MainActor in
            await exchangeCodeForToken(code)
        }
        showingWebView = false
    }

    private func saveTokens(accessToken: String, refreshToken: String?, expirationDate: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        tokenExpirationDate = expirationDate

        // Save to Keychain
        KeychainManager.save(
            value: accessToken,
            service: keychainServiceBase,
            account: KeychainKey.accessToken,
        )

        if let refreshToken {
            KeychainManager.save(
                value: refreshToken,
                service: keychainServiceBase,
                account: KeychainKey.refreshToken,
            )
        }

        KeychainManager.save(
            value: ISO8601DateFormatter().string(from: expirationDate),
            service: keychainServiceBase,
            account: KeychainKey.tokenExpiration,
        )
    }

    public func logout() {
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
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    _ = try await getValidAccessToken()
                    let request = try makeAuthorizedRequest(url: URL(string: "https://oauth.reddit.com/api/v1/me")!)

                    let (data, response) = try await URLSession.shared.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw RedditError.invalidResponse
                    }

                    if httpResponse.statusCode == 200 {
                        let userInfo = try JSONDecoder().decode(RedditUserInfo.self, from: data)
                        continuation.resume(returning: userInfo)
                    } else {
                        throw RedditError.httpError(statusCode: httpResponse.statusCode)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    private func exchangeCodeForToken(_ code: String) async {
        isLoading = true
        error = nil

        do {
            let tokenURL = URL(string: "https://www.reddit.com/api/v1/access_token")!
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"

            let authString = "\(clientId):"
            let authData = authString.data(using: .utf8)!.base64EncodedString()
            request.setValue("Basic \(authData)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let parameters = [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectUri,
            ]

            request.httpBody = parameters.percentEncoded()

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RedditError.invalidResponse
            }

            if httpResponse.statusCode == 200 {
                let tokenResponse = try JSONDecoder().decode(RedditTokenResponse.self, from: data)
                handleTokenResponse(tokenResponse)
            } else {
                throw RedditError.httpError(statusCode: httpResponse.statusCode)
            }
        } catch {
            handleError(error)
        }

        isLoading = false
    }

    @MainActor
    public func refreshAccessToken() async throws {
        guard let refreshToken else {
            throw RedditError.noRefreshToken
        }

        let tokenURL = URL(string: "https://www.reddit.com/api/v1/access_token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"

        let authString = "\(clientId):"
        let authData = authString.data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(authData)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let parameters = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]

        request.httpBody = parameters.percentEncoded()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RedditError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let tokenResponse = try JSONDecoder().decode(RedditTokenResponse.self, from: data)
            handleTokenResponse(tokenResponse)
        } else {
            throw RedditError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    @MainActor
    private func handleTokenResponse(_ response: RedditTokenResponse) {
        let expirationDate = Date().addingTimeInterval(TimeInterval(response.expires_in))
        saveTokens(
            accessToken: response.access_token,
            refreshToken: response.refresh_token,
            expirationDate: expirationDate,
        )

        isAuthenticated = true
        Task {
            await fetchUsername()
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
            } catch {
                // If refresh fails, clear tokens and throw error
                logout()
                throw RedditError.noAccessToken
            }
        }

        throw RedditError.noAccessToken
    }

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
    private func fetchUsername() async {
        do {
            let userInfo = try await fetchUserInfo()
            username = userInfo.name
        } catch {
            handleError(error)
        }
    }

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

public struct RedditUserInfo: Codable {
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
    func percentEncoded() -> Data {
        map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
        .data(using: .utf8)!
    }
}
