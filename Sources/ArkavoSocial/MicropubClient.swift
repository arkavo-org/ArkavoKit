import Foundation
import SwiftUI

public class MicropubClient: ObservableObject {
    // MARK: - Published Properties

    @MainActor @Published public var isAuthenticated = false
    @MainActor @Published public var isLoading = false
    @MainActor @Published public var error: MicropubError?
    @MainActor @Published public var siteConfig: MicropubConfig?

    // MARK: - Private Properties

    private let clientId: String
    private let redirectUri: String
    private let keychainServiceBase = "com.arkavo.micropub"
    @MainActor private var pendingOAuthState: String?
    @MainActor private var sessionGeneration: UInt64 = 0

    private enum KeychainKey {
        static let accessToken = "access_token"
        static let micropubEndpoint = "micropub_endpoint"
        static let mediaEndpoint = "media_endpoint"
    }

    // MARK: - Initialization

    public init(clientId: String, redirectUri: String = "arkavocreator://oauth/micropub") {
        self.clientId = clientId
        self.redirectUri = redirectUri
    }

    // MARK: - Endpoint & Header Validation

    static func validatedEndpointURL(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty
        else {
            throw MicropubError.badRequest("Invalid endpoint URL")
        }

        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw MicropubError.badRequest("Endpoint URL must use HTTPS")
        }

        return url
    }

    private static func sanitizeHeaderFilename(_ filename: String) -> String {
        let stripped = filename
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return stripped.isEmpty ? "upload" : stripped
    }

    private static func sanitizeContentType(_ contentType: String) -> String {
        let stripped = contentType
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? "application/octet-stream" : stripped
    }

    // MARK: - Token Management

    @MainActor
    public func loadStoredTokens() {
        let accessToken = KeychainManager.getValue(
            service: keychainServiceBase,
            account: KeychainKey.accessToken,
        )
        let micropubEndpoint = KeychainManager.getValue(
            service: keychainServiceBase,
            account: KeychainKey.micropubEndpoint,
        )

        isAuthenticated = accessToken != nil
        if isAuthenticated {
            if let micropubEndpoint {
                // Create config from stored endpoint
                siteConfig = MicropubConfig(
                    micropubEndpoint: micropubEndpoint,
                    mediaEndpoint: KeychainManager.getValue(
                        service: keychainServiceBase,
                        account: KeychainKey.mediaEndpoint,
                    ),
                    destinations: [],
                    postTypes: [],
                    channels: [],
                    syndicateTo: [],
                )
            }

            let generation = sessionGeneration
            Task { @MainActor in
                await fetchConfig(expectedGeneration: generation)
            }
        }
    }

    private func saveTokens(accessToken: String) {
        KeychainManager.save(
            value: accessToken,
            service: keychainServiceBase,
            account: KeychainKey.accessToken,
        )
    }

    @MainActor
    public func logout() {
        sessionGeneration &+= 1
        pendingOAuthState = nil
        try? KeychainManager.delete(service: keychainServiceBase, account: KeychainKey.accessToken)
        try? KeychainManager.delete(service: keychainServiceBase, account: KeychainKey.micropubEndpoint)
        try? KeychainManager.delete(service: keychainServiceBase, account: KeychainKey.mediaEndpoint)
        isAuthenticated = false
        siteConfig = nil
    }

    // MARK: - Authentication

    @MainActor
    public var authURL: URL {
        let state = UUID().uuidString
        pendingOAuthState = state

        var components = URLComponents(string: "https://micro.blog/indieauth/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "create update delete"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    @MainActor
    public func handleCallback(_ url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MicropubError.invalidCallback
        }

        let queryItems = components.queryItems ?? []
        if queryItems.contains(where: { $0.name == "error" }) {
            pendingOAuthState = nil
            throw MicropubError.invalidCallback
        }

        guard let expectedState = pendingOAuthState,
              let returnedState = queryItems.first(where: { $0.name == "state" })?.value,
              returnedState == expectedState,
              let code = queryItems.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            pendingOAuthState = nil
            throw MicropubError.invalidCallback
        }
        pendingOAuthState = nil

        let generation = sessionGeneration
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            try await exchangeCodeForToken(code, expectedGeneration: generation)
            guard sessionGeneration == generation else { return }
            isAuthenticated = true
            await fetchConfig(expectedGeneration: generation)
        } catch {
            if sessionGeneration == generation {
                handleError(error)
            }
            throw error
        }
    }

    @MainActor
    private func exchangeCodeForToken(_ code: String, expectedGeneration: UInt64) async throws {
        let tokenURL = URL(string: "https://micro.blog/indieauth/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let parameters = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientId,
            "redirect_uri": redirectUri,
        ]

        request.httpBody = parameters.percentEncoded()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard sessionGeneration == expectedGeneration else { return }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MicropubError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            guard sessionGeneration == expectedGeneration else { return }
            saveTokens(accessToken: tokenResponse.access_token)
        } else {
            throw MicropubError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - API Methods

    @MainActor
    private func fetchConfig(expectedGeneration: UInt64? = nil) async {
        let generation = expectedGeneration ?? sessionGeneration
        do {
            let config = try await queryConfig()
            guard sessionGeneration == generation else { return }
            siteConfig = config

            // Store endpoints in keychain
            if let micropubEndpoint = config.micropubEndpoint {
                KeychainManager.save(
                    value: micropubEndpoint,
                    service: keychainServiceBase,
                    account: KeychainKey.micropubEndpoint,
                )
            }

            if let mediaEndpoint = config.mediaEndpoint {
                KeychainManager.save(
                    value: mediaEndpoint,
                    service: keychainServiceBase,
                    account: KeychainKey.mediaEndpoint,
                )
            }
        } catch {
            if sessionGeneration == generation {
                handleError(error)
            }
        }
    }

    @MainActor
    public func createPost(content: String, title: String? = nil, images: [URL] = []) async throws -> URL {
        // First ensure we have config
        if siteConfig == nil {
            await fetchConfig()
        }

        guard let micropubEndpoint = siteConfig?.micropubEndpoint else {
            throw MicropubError.missingEndpoint
        }
        let endpointURL = try Self.validatedEndpointURL(micropubEndpoint)

        // Format according to Micropub spec
        var properties: [String: [String]] = [
            "content": [content],
        ]

        if let title {
            properties["name"] = [title]
        }

        if !images.isEmpty {
            properties["photo"] = images.map(\.absoluteString)
        }

        let postData: [String: Any] = [
            "type": ["h-entry"],
            "properties": properties,
        ]

        var request = try makeAuthorizedRequest(
            url: endpointURL,
            method: "POST",
            contentType: "application/json",
        )

        let jsonData = try JSONSerialization.data(withJSONObject: postData)
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MicropubError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 201, 202:
            if let location = httpResponse.value(forHTTPHeaderField: "Location"),
               let postURL = URL(string: location)
            {
                return postURL
            } else {
                // Some Micropub endpoints don't return Location header
                return URL(string: "https://micro.blog")!
            }
        case 400:
            // Try to decode the error response
            if let errorResponse = try? JSONDecoder().decode(MicropubErrorResponse.self, from: data) {
                if errorResponse.error == "invalid_request",
                   errorResponse.error_description.contains("payment method")
                {
                    throw MicropubError.paymentRequired
                } else {
                    throw MicropubError.apiError(
                        error: errorResponse.error,
                        description: errorResponse.error_description,
                    )
                }
            } else {
                throw MicropubError.httpError(statusCode: httpResponse.statusCode)
            }
        default:
            throw MicropubError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    @MainActor
    public func uploadMedia(data: Data, filename: String, contentType: String) async throws -> URL {
        guard let mediaEndpoint = siteConfig?.mediaEndpoint else {
            throw MicropubError.missingEndpoint
        }
        let endpointURL = try Self.validatedEndpointURL(mediaEndpoint)

        let safeFilename = Self.sanitizeHeaderFilename(filename)
        let safeContentType = Self.sanitizeContentType(contentType)

        let boundary = UUID().uuidString
        var request = try makeAuthorizedRequest(
            url: endpointURL,
            method: "POST",
            contentType: "multipart/form-data; boundary=\(boundary)",
        )

        var bodyData = Data()
        bodyData.append(Data("--\(boundary)\r\n".utf8))
        bodyData.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n".utf8))
        bodyData.append(Data("Content-Type: \(safeContentType)\r\n\r\n".utf8))
        bodyData.append(data)
        bodyData.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = bodyData

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MicropubError.invalidResponse
        }

        if httpResponse.statusCode == 201,
           let location = httpResponse.value(forHTTPHeaderField: "Location"),
           let mediaURL = URL(string: location)
        {
            return mediaURL
        } else {
            throw MicropubError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    @MainActor
    private func queryConfig() async throws -> MicropubConfig {
        let request = try makeAuthorizedRequest(
            url: URL(string: "https://micro.blog/micropub?q=config")!,
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MicropubError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            do {
                let decoder = JSONDecoder()
                var config = try decoder.decode(MicropubConfig.self, from: data)

                // Set default endpoint if not provided
                if config.micropubEndpoint == nil {
                    // Create mutable copy with default endpoint
                    config = MicropubConfig(
                        micropubEndpoint: "https://micro.blog/micropub",
                        mediaEndpoint: config.mediaEndpoint,
                        destinations: config.destinations,
                        postTypes: config.postTypes,
                        channels: config.channels,
                        syndicateTo: config.syndicateTo,
                    )
                }

                return config
            } catch {
                print("Config decoding error: \(error)")
                throw MicropubError.decodingError(error)
            }
        } else {
            throw MicropubError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    private func makeAuthorizedRequest(
        url: URL,
        method: String = "GET",
        contentType: String = "application/json"
    ) throws -> URLRequest {
        guard let accessToken = KeychainManager.getValue(
            service: keychainServiceBase,
            account: KeychainKey.accessToken,
        ) else {
            throw MicropubError.noAccessToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    @MainActor
    private func handleError(_ error: Error) {
        if let micropubError = error as? MicropubError {
            self.error = micropubError
        } else {
            self.error = .unknown(error)
        }
    }
}

// MARK: - Supporting Types

struct MicropubConfigResponse: Codable {
    let micropubEndpoint: String?
    let mediaEndpoint: String?
    let syndicateTo: [SyndicationTarget]?

    private enum CodingKeys: String, CodingKey {
        case micropubEndpoint = "micropub-endpoint"
        case mediaEndpoint = "media-endpoint"
        case syndicateTo = "syndicate-to"
    }
}

public struct MicropubConfig: Codable, Sendable {
    public let micropubEndpoint: String?
    public let mediaEndpoint: String?
    public let destinations: [Destination]
    public let postTypes: [PostType]
    public let channels: [Channel]
    public let syndicateTo: [SyndicationTarget]

    private enum CodingKeys: String, CodingKey {
        case micropubEndpoint = "micropub-endpoint"
        case mediaEndpoint = "media-endpoint"
        case destinations = "destination"
        case postTypes = "post-types"
        case channels
        case syndicateTo = "syndicate-to"
    }
}

public struct Destination: Codable, Identifiable, Sendable {
    public var id: String { uid }
    public let uid: String
    public let name: String
    public let microblogAudio: Bool
    public let microblogDefault: Bool
    public let microblogTitle: String

    private enum CodingKeys: String, CodingKey {
        case uid, name
        case microblogAudio = "microblog-audio"
        case microblogDefault = "microblog-default"
        case microblogTitle = "microblog-title"
    }
}

public struct PostType: Codable, Identifiable, Hashable, Sendable {
    public var id: String { type }
    public let type: String
    public let name: String
    public let properties: [String]
}

public struct Channel: Codable, Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public let uid: String
    public let name: String
}

public struct SyndicationTarget: Codable, Identifiable, Sendable {
    public var id: String { uid }
    public let uid: String
    public let name: String
}

struct TokenResponse: Codable {
    let access_token: String
    let scope: String
    let me: String
}

private struct MicropubErrorResponse: Decodable {
    let error: String
    let error_description: String
}

public enum MicropubError: LocalizedError {
    case invalidCallback
    case invalidResponse
    case noAccessToken
    case missingEndpoint
    case httpError(statusCode: Int)
    case badRequest(String)
    case unknown(Error)
    case decodingError(Error)
    case apiError(error: String, description: String)
    case paymentRequired

    public var errorDescription: String? {
        switch self {
        case .invalidCallback:
            "Invalid OAuth callback received"
        case .invalidResponse:
            "Invalid response from server"
        case .noAccessToken:
            "No access token available"
        case .missingEndpoint:
            "Micropub endpoint not configured"
        case let .httpError(statusCode):
            "HTTP error: \(statusCode)"
        case let .badRequest(message):
            "Bad request: \(message)"
        case let .decodingError(error):
            "Decoding error: \(error.localizedDescription)"
        case .paymentRequired:
            "A payment method is required to post during your Micro.blog trial"
        case let .apiError(_, description):
            description
        case let .unknown(error):
            "Unknown error: \(error.localizedDescription)"
        }
    }
}
