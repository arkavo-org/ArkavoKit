import AuthenticationServices
import Foundation
import SwiftUI

public struct Patron: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let email: String?
    public let avatarURL: URL?
    public let status: PatronStatus
    public let tierAmount: Double
    public let lifetimeSupport: Double
    public let joinDate: Date
    public let url: URL?

    public enum PatronStatus: String, Sendable {
        case active = "Active"
        case inactive = "Inactive"
        case new = "New"

        public var color: Color {
            switch self {
            case .active: .green
            case .inactive: .red
            case .new: .blue
            }
        }
    }
}

// MARK: - Patreon API Client

public actor PatreonClient: ObservableObject {
    let clientId: String
    let clientSecret: String
    public var config: PatreonConfig = .init()
    public static var redirectURI: String { ArkavoConfiguration.shared.oauthRedirectURL(for: "patreon") }
    private let urlSession: URLSession

    @MainActor @Published public var isAuthenticated = false
    @MainActor @Published public var isLoading = false
    @MainActor @Published public var error: Error?

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        urlSession = URLSession(configuration: URLSessionConfiguration.default)
        Task { @MainActor in
            checkExistingAuth()
        }
    }

    deinit {
        urlSession.finishTasksAndInvalidate()
    }

    // API Endpoints
    private enum Endpoint: Equatable {
        case identity
        case campaigns
        case campaign(id: String)
        case campaignMembers(id: String)
        case member(id: String)
        case oauthToken

        var path: String {
            switch self {
            case .identity: "identity"
            case .campaigns: "campaigns"
            case let .campaign(id): "campaigns/\(id)"
            case let .campaignMembers(id): "campaigns/\(id)/members"
            case let .member(id): "members/\(id)"
            case .oauthToken: "token"
            }
        }

        var url: URL {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "www.patreon.com"
            components.path = self == .oauthToken
                ? "/api/oauth2/token"
                : "/api/oauth2/v2/\(path)"
            return components.url!
        }
    }

    // MARK: - Authentication Methods

    @MainActor
    private func checkExistingAuth() {
        isAuthenticated = KeychainManager.getAccessToken() != nil
    }

    @MainActor
    public func isCreator() async -> Bool {
        guard isAuthenticated else { return false }

        do {
            _ = try await getUserIdentity()
            let campaigns = try await getCampaigns()
            // User is considered a creator if they have any campaigns
            return !campaigns.data.isEmpty
        } catch {
            return false
        }
    }

    @MainActor
    public func handleCallback(_ url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw PatreonError.invalidCallback
        }

        isLoading = true
        error = nil

        do {
            try await exchangeCodeForTokens(code)
            isLoading = false
        } catch {
            self.error = error as? PatreonError ?? .authorizationFailed
            isLoading = false
            throw error
        }
    }

    private func exchangeCodeForTokens(_ code: String) async throws {
        let token = try await exchangeCode(code)

        try KeychainManager.saveTokens(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
        )

        await MainActor.run {
            isAuthenticated = true
            isLoading = false
        }
    }

    @MainActor
    public func logout() {
        KeychainManager.deleteTokens()
        isAuthenticated = false
        error = nil
    }

    // MARK: - API Methods

    public func getPatrons() async throws -> [Patron] {
        let members = try await getMembers()
        let sortedMembers = members.sorted { $0.tierAmount > $1.tierAmount }
        return sortedMembers
    }

    public func getTierDetails() async throws -> [PatreonTier] {
        let tiers = try await getTiers()
        return tiers.sorted { $0.amount > $1.amount }
    }

    public func getCampaignStats() async throws -> (totalPatrons: Int, monthlyIncome: Double) {
        let campaign = try await getCampaignDetails()
        guard let firstCampaign = campaign.data.first else {
            throw PatreonError.invalidResponse
        }

        let patronCount = firstCampaign.attributes.patron_count
        let patrons = try await getPatrons()
        let monthlyIncome = patrons.reduce(0.0) { $0 + $1.tierAmount }

        return (patronCount, monthlyIncome)
    }

    public func refreshAuthIfNeeded() async throws {
        guard let rToken = KeychainManager.getRefreshToken() else { return }
        let token = try await refreshToken(rToken)
        try KeychainManager.saveTokens(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
        )
    }

    // Public API Methods
    public func getUserIdentity() async throws -> UserIdentity {
        try await request(
            endpoint: .identity,
            accessToken: config.creatorAccessToken,
            queryItems: [
                URLQueryItem(name: "include", value: "memberships.campaign,memberships.currently_entitled_tiers"),
                URLQueryItem(name: "fields[user]", value: UserFields.allCases.map(\.rawValue).joined(separator: ",")),
                URLQueryItem(name: "fields[member]", value: MemberFields.allCases.map(\.rawValue).joined(separator: ",")),
            ],
        )
    }

    public func getCampaignDetails() async throws -> CampaignResponse {
        guard let campaignId = config.campaignId else { throw PatreonError.missingCampaignId }
        let response: CampaignResponse = try await request(
            endpoint: .campaign(id: campaignId),
            accessToken: config.creatorAccessToken,
            queryItems: [
                URLQueryItem(name: "include", value: "creator,tiers,benefits.tiers,goals"),
                URLQueryItem(name: "fields[campaign]", value: CampaignFields.allCases.map(\.rawValue).joined(separator: ",")),
                URLQueryItem(name: "fields[tier]", value: TierFields.allCases.map(\.rawValue).joined(separator: ",")),
            ],
        )
        return response
    }

    public func getCampaignMembers() async throws -> [Member] {
        guard let campaignId = config.campaignId else { throw PatreonError.missingCampaignId }
        let response: [Member] = try await request(
            endpoint: .campaignMembers(id: campaignId),
            accessToken: config.creatorAccessToken,
            queryItems: [
                URLQueryItem(name: "include", value: "user,address,campaign,currently_entitled_tiers"),
                URLQueryItem(name: "fields[member]", value: MemberFields.allCases.map(\.rawValue).joined(separator: ",")),
            ],
        )
        return response
    }

    @MainActor
    public var authURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.patreon.com"
        components.path = "/oauth2/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: PatreonClient.redirectURI),
            URLQueryItem(name: "scope", value: "identity"),
            URLQueryItem(name: "state", value: UUID().uuidString),
        ]

        return components.url!
    }

    public func getOAuthURL() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.patreon.com"
        components.path = "/oauth2/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: PatreonClient.redirectURI),
            URLQueryItem(name: "scope", value: "identity"),
            URLQueryItem(name: "state", value: UUID().uuidString),
        ]

        return components.url!
    }

    public func exchangeCode(_ code: String) async throws -> OAuthToken {
        let params = [
            "code": code,
            "grant_type": "authorization_code",
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": PatreonClient.redirectURI,
        ]

        return try await request(
            endpoint: .oauthToken,
            method: "POST",
            body: params,
        )
    }

    public func refreshToken(_ refreshToken: String) async throws -> OAuthToken {
        let params = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
            "client_secret": clientSecret,
        ]

        return try await request(
            endpoint: .oauthToken,
            method: "POST",
            body: params,
        )
    }

    public func getMembers() async throws -> [Patron] {
        guard let campaignId = config.campaignId else { throw PatreonError.missingCampaignId }
        let response: MemberResponse = try await request(
            endpoint: .campaignMembers(id: campaignId),
            accessToken: config.creatorAccessToken,
            queryItems: [
                URLQueryItem(name: "include", value: "user,currently_entitled_tiers"),
                URLQueryItem(name: "fields[member]", value: "full_name,email,patron_status,last_charge_date,currently_entitled_amount_cents,lifetime_support_cents"),
                URLQueryItem(name: "fields[user]", value: "thumb_url,url"),
                URLQueryItem(name: "page[count]", value: "100"),
            ],
        )

        return response.data.map { member in
            let userData = response.included.first { included in
                included.id == member.relationships.user.data.id && included.type == "user"
            }
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            return Patron(
                id: member.id,
                name: member.attributes.fullName,
                email: member.attributes.email,
                avatarURL: URL(string: userData?.attributes.thumbUrl ?? ""),
                status: patronStatus(from: member.attributes.patronStatus),
                tierAmount: Double(member.attributes.currentlyEntitledAmountCents) / 100.0,
                lifetimeSupport: Double(member.attributes.lifetimeSupportCents) / 100.0,
                joinDate: member.attributes.lastChargeDate.flatMap { dateFormatter.date(from: $0) } ?? Date(),
                url: URL(string: userData?.attributes.url ?? ""),
            )
        }
    }

    private func patronStatus(from status: String) -> Patron.PatronStatus {
        switch status.lowercased() {
        case "active_patron": .active
        case "declined_patron", "former_patron": .inactive
        default: .new
        }
    }

    private func request<T: Decodable>(
        endpoint: Endpoint,
        method: String = "GET",
        accessToken: String? = nil,
        queryItems: [URLQueryItem] = [],
        body: [String: String]? = nil
    ) async throws -> T {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = method

        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.map { key, value in
                "\(key)=\(value)"
            }.joined(separator: "&").data(using: .utf8)
        }

        if !queryItems.isEmpty {
            var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false)!
            components.queryItems = queryItems.map { URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)) }
            request.url = components.url
        }
//        print("rewritten url: \(request.url!)")
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PatreonError.invalidResponse
        }

        guard 200 ... 299 ~= httpResponse.statusCode else {
            if httpResponse.statusCode == 400 {
                let errorResponse = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
                if let firstError = errorResponse?.errors.first {
                    throw PatreonError.apiError(firstError)
                }
            }
            throw PatreonError.httpError(statusCode: httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PatreonError.decodingError(error)
        }
    }
}

// MARK: - Configuration

public struct PatreonConfig: Sendable {
    var creatorAccessToken: String? {
        get { KeychainManager.getAccessToken() }
        set {
            if let newValue {
                try? KeychainManager.save(newValue.data(using: .utf8)!,
                                          service: "com.arkavo.patreon",
                                          account: "access_token")
            } else {
                try? KeychainManager.delete(service: "com.arkavo.patreon",
                                            account: "access_token")
            }
        }
    }

    var creatorRefreshToken: String? {
        get { KeychainManager.getRefreshToken() }
        set {
            if let newValue {
                try? KeychainManager.save(newValue.data(using: .utf8)!,
                                          service: "com.arkavo.patreon",
                                          account: "refresh_token")
            } else {
                try? KeychainManager.delete(service: "com.arkavo.patreon",
                                            account: "refresh_token")
            }
        }
    }

    var campaignId: String? {
        get { KeychainManager.getCampaignId() }
        set {
            if let newValue {
                try? KeychainManager.save(newValue.data(using: .utf8)!,
                                          service: "com.arkavo.patreon",
                                          account: "campaign_id")
            } else {}
        }
    }
}

// MARK: - Models

// Base Resource Object (follows JSON:API specification)
public struct ResourceObject: Codable {
    public let type: String
    public let id: String
    public let attributes: [String: AnyCodable]
    public let relationships: [String: Relationship]?

    public struct Relationship: Codable {
        public let data: RelationshipData
        public let links: Links?

        public struct Links: Codable, Sendable {
            public let related: String?
            public let `self`: String?
        }
    }

    public struct RelationshipData: Codable, Sendable {
        public let type: String
        public let id: String
    }
}

// User Data Models
public struct UserData: Codable, Sendable {
    public let type: String
    public let id: String
    public let attributes: UserAttributes
    public let relationships: UserRelationships

    public struct UserAttributes: Codable, Sendable {
        public let email: String?
        public let fullName: String
        public let isEmailVerified: Bool?
        public let imageUrl: String?
        public let thumbUrl: String?
        public let socialConnections: SocialConnections?

        private enum CodingKeys: String, CodingKey {
            case email
            case fullName = "full_name"
            case isEmailVerified = "is_email_verified"
            case imageUrl = "image_url"
            case thumbUrl = "thumb_url"
            case socialConnections = "social_connections"
        }
    }

    public struct UserRelationships: Codable, Sendable {
        public let memberships: Memberships

        public struct Memberships: Codable, Sendable {
            public let data: [ResourceObject.RelationshipData]
        }
    }
}

// Social Connections Model
public struct SocialConnections: Codable, Sendable {
    public let discord: Platform?
    public let twitter: Platform?
    public let youtube: Platform?
    public let twitch: Platform?

    public struct Platform: Codable, Sendable {
        public let userId: String
        public let url: String?
        public let scopes: [String]?

        private enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case url
            case scopes
        }
    }
}

// Campaign Data Models
public struct CampaignData: Codable {
    public let type: String
    public let id: String
    public let attributes: CampaignAttributes
    public let relationships: CampaignRelationships

    public struct CampaignAttributes: Codable {
        public let createdAt: String
        public let creationName: String?
        public let isMonthly: Bool
        public let isNSFW: Bool
        public let patronCount: Int
        public let pledgeUrl: String
        public let publishedAt: String?
        public let summary: String?
        public let url: String

        private enum CodingKeys: String, CodingKey {
            case createdAt = "created_at"
            case creationName = "creation_name"
            case isMonthly = "is_monthly"
            case isNSFW = "is_nsfw"
            case patronCount = "patron_count"
            case pledgeUrl = "pledge_url"
            case publishedAt = "published_at"
            case summary
            case url
        }
    }

    public struct CampaignRelationships: Codable {
        public let creator: ResourceObject.Relationship
        public let tiers: ResourceObject.Relationship?
        public let benefits: ResourceObject.Relationship?
        public let goals: ResourceObject.Relationship?
    }
}

// Member Models
public struct MemberAttributes: Codable {
    public let campaignLifetimeSupportCents: Int
    public let currentlyEntitledAmountCents: Int
    public let email: String?
    public let fullName: String
    public let isFollower: Bool
    public let lastChargeDate: String?
    public let lastChargeStatus: String?
    public let lifetimeSupportCents: Int
    public let patronStatus: String?
    public let pledgeCadence: Int?
    public let willPayAmountCents: Int

    private enum CodingKeys: String, CodingKey {
        case campaignLifetimeSupportCents = "campaign_lifetime_support_cents"
        case currentlyEntitledAmountCents = "currently_entitled_amount_cents"
        case email
        case fullName = "full_name"
        case isFollower = "is_follower"
        case lastChargeDate = "last_charge_date"
        case lastChargeStatus = "last_charge_status"
        case lifetimeSupportCents = "lifetime_support_cents"
        case patronStatus = "patron_status"
        case pledgeCadence = "pledge_cadence"
        case willPayAmountCents = "will_pay_amount_cents"
    }
}

// AnyCodable wrapper for handling dynamic JSON values
public struct AnyCodable: Codable, Sendable {
    // We'll use an enum to restrict possible values to Sendable types
    private enum Storage: Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([AnyCodable])
        case dictionary([String: AnyCodable])
    }

    private let storage: Storage

    public var value: Any {
        switch storage {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(value):
            value.map(\.value)
        case let .dictionary(value):
            value.mapValues(\.value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            storage = .null
        } else if let bool = try? container.decode(Bool.self) {
            storage = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            storage = .int(int)
        } else if let double = try? container.decode(Double.self) {
            storage = .double(double)
        } else if let string = try? container.decode(String.self) {
            storage = .string(string)
        } else if let array = try? container.decode([AnyCodable].self) {
            storage = .array(array)
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            storage = .dictionary(dictionary)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable cannot decode value",
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch storage {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .dictionary(value):
            try container.encode(value)
        }
    }

    public init(_ value: Any) {
        switch value {
        case is NSNull:
            storage = .null
        case let bool as Bool:
            storage = .bool(bool)
        case let int as Int:
            storage = .int(int)
        case let double as Double:
            storage = .double(double)
        case let string as String:
            storage = .string(string)
        case let array as [Any]:
            storage = .array(array.map(AnyCodable.init))
        case let dictionary as [String: Any]:
            storage = .dictionary(dictionary.mapValues(AnyCodable.init))
        default:
            storage = .null // Default to null for unsupported types
        }
    }
}

public struct UserIdentity: Codable, Sendable {
    public let data: UserData
    public let links: ResourceObject.Relationship.Links?
}

public struct Member: Codable {
    public let attributes: MemberAttributes
    public let id: String
    public let type: String
}

public struct OAuthToken: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int
    public let scope: String
    public let tokenType: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

// MARK: - Field Enums

private enum UserFields: String, CaseIterable {
    case about, email, fullName = "full_name", imageUrl = "image_url"
}

private enum CampaignFields: String, CaseIterable {
    case createdAt = "created_at", patronCount = "patron_count", url
}

private enum TierFields: String, CaseIterable {
    case amountCents = "amount_cents", description, title
}

private enum MemberFields: String, CaseIterable {
    case email, fullName = "full_name", patronStatus = "patron_status"
}

public extension PatreonClient {
    struct CampaignResponse: Codable, Sendable {
        public let data: [CampaignData]
        public let included: [IncludedData]
        public let meta: MetaData

        public struct CampaignData: Codable, Sendable {
            public let id: String
            public let type: String
            public let attributes: CampaignAttributes
            public let relationships: CampaignRelationships
        }

        public struct CampaignAttributes: Codable, Sendable {
            public let created_at: String
            public let creation_name: String?
            public let is_monthly: Bool
            public let is_nsfw: Bool
            public let patron_count: Int
            public let published_at: String?
            public let summary: String?
        }

        public struct CampaignRelationships: Codable, Sendable {
            public let creator: RelationshipData
            public let goals: Goals
            public let tiers: Tiers

            public struct RelationshipData: Codable, Sendable {
                public let data: CreatorData
                public let links: Links

                public struct CreatorData: Codable, Sendable {
                    public let id: String
                    public let type: String
                }

                public struct Links: Codable, Sendable {
                    public let related: String
                }
            }

            public struct Goals: Codable, Sendable {
                public let data: [String]?
            }

            public struct Tiers: Codable, Sendable {
                public let data: [TierData]

                public struct TierData: Codable, Sendable {
                    public let id: String
                    public let type: String
                }
            }
        }

        public struct IncludedData: Codable, Sendable {
            public let attributes: [String: AnyCodable]
            public let id: String
            public let type: String
        }

        public struct MetaData: Codable, Sendable {
            public let pagination: Pagination

            public struct Pagination: Codable, Sendable {
                public let cursors: Cursors
                public let total: Int

                public struct Cursors: Codable, Sendable {
                    public let next: String?
                }
            }
        }
    }

    func getCampaigns() async throws -> CampaignResponse {
        try await request(
            endpoint: .campaigns,
            accessToken: config.creatorAccessToken,
            queryItems: [
                URLQueryItem(name: "include", value: "creator,tiers,goals"),
                URLQueryItem(name: "fields[campaign]", value: "summary,creation_name,patron_count,created_at,published_at,is_monthly,is_nsfw"),
                URLQueryItem(name: "fields[tier]", value: "amount_cents,description,title,patron_count,discord_role_ids,edited_at,image_url,published,published_at,remaining,requires_shipping,user_limit"),
            ],
        )
    }
}

public enum PatreonError: LocalizedError {
    case invalidURL
    case invalidCallback
    case invalidResponse
    case authorizationFailed
    case tokenExchangeFailed
    case networkError
    case missingCampaignId
    case httpError(statusCode: Int)
    case decodingError(Error)
    case apiError(APIError)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid URL"
        case .invalidCallback:
            "Invalid callback URL"
        case .invalidResponse:
            "Invalid response from server"
        case let .httpError(statusCode):
            "HTTP error: \(statusCode)"
        case let .decodingError(error):
            "Decoding error: \(error.localizedDescription)"
        case let .apiError(error):
            error.detail ?? error.title
        case .authorizationFailed:
            "Authorization failed"
        case .tokenExchangeFailed:
            "Token exchange failed"
        case .networkError:
            "Network error"
        case .missingCampaignId:
            "Missing campaign ID"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case let .apiError(error):
            if error.code == 1 {
                return "Please check the API parameters and try again"
            }
            return nil
        default:
            return nil
        }
    }
}

struct APIErrorResponse: Decodable {
    let errors: [APIError]
}

public struct APIError: Decodable, Sendable {
    public let code: Int
    public let code_name: String
    public let detail: String?
    public let id: String
    public let status: String
    public let title: String
    public let challenge_metadata: ChallengeMetadata?

    public struct ChallengeMetadata: Decodable, Sendable {
        // Add fields as needed based on what the API returns
    }
}

// MARK: - Tier Models

public extension PatreonClient {
    struct TierData: Codable {
        let id: String
        let attributes: TierAttributes
        let type: String

        struct TierAttributes: Codable {
            let amount_cents: Int
            let description: String?
            let title: String
            let patron_count: Int?

            var amount: Double {
                Double(amount_cents) / 100.0
            }
        }
    }

    func getTiers() async throws -> [PatreonTier] {
        let response = try await getCampaigns()

        // Find tiers in the included data
        let tierData = response.included.filter { $0.type == "tier" }

        return tierData.compactMap { included -> PatreonTier? in
            guard let amountCents = included.attributes["amount_cents"]?.value as? Int,
                  let title = included.attributes["title"]?.value as? String
            else {
                return nil
            }

            return PatreonTier(
                id: included.id,
                name: title,
                description: included.attributes["description"]?.value as? String,
                amount: Double(amountCents) / 100.0,
                patronCount: included.attributes["patron_count"]?.value as? Int,
            )
        }
    }
}

public struct PatreonTier: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let amount: Double
    public let patronCount: Int?
}

// MARK: - Member Response Models

extension PatreonClient {
    struct MemberResponse: Codable {
        let data: [MemberData]
        let included: [IncludedData]
        let meta: MetaData

        struct MemberData: Codable {
            let attributes: MemberAttributes
            let id: String
            let relationships: MemberRelationships
            let type: String
        }

        struct MemberAttributes: Codable {
            let currentlyEntitledAmountCents: Int
            let email: String?
            let fullName: String
            let lastChargeDate: String?
            let lifetimeSupportCents: Int
            let patronStatus: String

            enum CodingKeys: String, CodingKey {
                case currentlyEntitledAmountCents = "currently_entitled_amount_cents"
                case email
                case fullName = "full_name"
                case lastChargeDate = "last_charge_date"
                case lifetimeSupportCents = "lifetime_support_cents"
                case patronStatus = "patron_status"
            }
        }

        struct MemberRelationships: Codable {
            let currentlyEntitledTiers: TierRelationship
            let user: UserRelationship

            enum CodingKeys: String, CodingKey {
                case currentlyEntitledTiers = "currently_entitled_tiers"
                case user
            }

            struct TierRelationship: Codable {
                let data: [TierData]

                struct TierData: Codable {
                    let id: String
                    let type: String
                }
            }

            struct UserRelationship: Codable {
                let data: UserData
                let links: Links

                struct UserData: Codable {
                    let id: String
                    let type: String
                }

                struct Links: Codable {
                    let related: String
                }
            }
        }

        struct IncludedData: Codable {
            let attributes: IncludedAttributes
            let id: String
            let type: String

            struct IncludedAttributes: Codable {
                let thumbUrl: String?
                let url: String?

                enum CodingKeys: String, CodingKey {
                    case thumbUrl = "thumb_url"
                    case url
                }
            }
        }

        struct MetaData: Codable {
            let pagination: Pagination

            struct Pagination: Codable {
                let cursors: Cursors
                let total: Int

                struct Cursors: Codable {
                    let next: String?
                }
            }
        }
    }
}
