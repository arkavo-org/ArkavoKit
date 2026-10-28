import Foundation
import Security

// Patreon without a client secret (Creator#121). Patreon's authorization runs
// on the device; identity exchanges the code (`POST /oauth/patreon/link`) and
// keeps the Patreon tokens. The membership reaches the app inside the signed
// Arkavo token (`arkavo_patreon`), read through a `PatreonAccountSource`.
// Nothing here logs a code, a state or a token.

/// Links a Patreon account to the signed-in Arkavo account.
///
/// 1. `authorization(redirectURI:)` gives the Patreon URL to open and the
///    `state` it carries.
/// 2. `PatreonAuthorization.code(from:)` checks the callback against that
///    `state`, before anything is sent anywhere.
/// 3. `link(code:redirectURI:)` sends the code to identity with the session token.
///
/// Then a renewed or new session token carries the membership.
public struct PatreonClient: Sendable {
    /// Identity derives the role from campaign ownership (`campaigns`) and
    /// reads the memberships (`identity.memberships`). No email.
    public static let scope = "identity identity.memberships campaigns"

    /// Creator's redirect: identity's bounce to `arkavocreator://oauth/patreon`.
    public static var defaultRedirectURI: String {
        ArkavoConfiguration.shared.oauthRedirectURL(for: "patreon")
    }

    public let clientID: String
    private let identity: URL
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let token: @Sendable () -> String?

    /// - Parameter token: the Arkavo session token the link is sent with; the stored one by default.
    public init(clientID: String, token: @escaping @Sendable () -> String? = { KeychainManager.getAuthenticationToken() }) {
        self.init(
            clientID: clientID,
            identity: ArkavoConfiguration.shared.identityURL,
            send: { try await ArkavoClient.identitySession.data(for: $0) },
            token: token
        )
    }

    init(
        clientID: String,
        identity: URL,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        token: @escaping @Sendable () -> String?
    ) {
        self.clientID = clientID
        self.identity = identity
        self.send = send
        self.token = token
    }

    // MARK: Authorization

    /// A new authorization with its own `state`. Keep it until its callback
    /// arrives, and use it for that callback only.
    ///
    /// - Parameter redirectURI: where Patreon sends the code. `link` must send the same one.
    public func authorization(redirectURI: String = PatreonClient.defaultRedirectURI) -> PatreonAuthorization {
        let state = Self.randomState()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.patreon.com"
        components.path = "/oauth2/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "state", value: state),
        ]
        return PatreonAuthorization(url: components.url!, state: state, redirectURI: redirectURI)
    }

    /// 32 random bytes, base64url without padding.
    private static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "the system random number generator failed")
        return Data(bytes).base64URLEncodedString()
    }

    // MARK: Link

    /// Sends a callback's code to identity, which exchanges it and binds the
    /// Patreon account to the signed-in Arkavo account.
    ///
    /// Only call it with a code `PatreonAuthorization.code(from:)` returned.
    ///
    /// - Parameter redirectURI: the authorization's `redirectURI`.
    /// - Throws: `PatreonLinkError`, chosen by status alone; or the transport's error.
    public func link(code: String, redirectURI: String) async throws -> PatreonLink {
        guard let token = token(), !token.isEmpty else { throw PatreonLinkError.signInRequired }
        var request = URLRequest(url: identity.appendingPathComponent("oauth/patreon/link"))
        request.httpMethod = "POST"
        // The shared cookie store is for the Apple link's nonce only.
        request.httpShouldHandleCookies = false
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No `role`: identity derives it from campaign ownership.
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["code": code, "redirect_uri": redirectURI],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )

        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("PatreonClient.link: status=\(status)")
        switch status {
        case 200:
            guard let reply = try? JSONDecoder().decode(LinkReply.self, from: data),
                  let role = PatreonAccount.Role(rawValue: reply.role)
            else { throw PatreonLinkError.unexpectedResponse }
            return PatreonLink(patreonUserID: reply.patreonUserID, role: role, campaignID: reply.campaignID)
        case 400: throw PatreonLinkError.misconfigured
        case 401: throw PatreonLinkError.signInRequired
        case 409: throw PatreonLinkError.linkedToAnotherAccount
        case 500: throw PatreonLinkError.serverFailure
        case 502: throw PatreonLinkError.patreonUnavailable
        case 503: throw PatreonLinkError.notConfigured
        default: throw PatreonLinkError.unexpectedResponse
        }
    }

    private struct LinkReply: Decodable {
        let patreonUserID: String
        let role: String
        let campaignID: String?

        enum CodingKeys: String, CodingKey {
            case patreonUserID = "patreon_user_id"
            case role
            case campaignID = "campaign_id"
        }
    }

    // MARK: Legacy tokens

    /// The keychain items the client-secret flow wrote (ArkavoKit 0.11 and earlier).
    static let legacyItems = [
        ("com.arkavo.patreon", "access_token"),
        ("com.arkavo.patreon", "refresh_token"),
        ("com.arkavo.patreon", "campaign_id"),
    ]

    /// Deletes the Patreon tokens and campaign id a client secret obtained, so
    /// none outlives the upgrade. Call it at launch; it does nothing once they are gone.
    public static func removeLegacyTokens() {
        removeLegacyTokens { service, account in try? KeychainManager.delete(service: service, account: account) }
    }

    static func removeLegacyTokens(delete: (String, String) -> Void) {
        for (service, account) in legacyItems {
            delete(service, account)
        }
    }
}

/// One authorization: the URL to open, and the `state` its callback must carry.
public struct PatreonAuthorization: Sendable, Equatable {
    public let url: URL
    public let state: String
    /// Send it with the code: identity's exchange must use the authorization's redirect.
    public let redirectURI: String

    /// The code of this authorization's callback.
    ///
    /// The callback must carry exactly one `state`, equal to this one: any
    /// other is refused before anything is sent, so a forged callback cannot
    /// bind another Patreon account. The callback's own URL is not compared:
    /// it may be the app's scheme, reached through identity's bounce.
    ///
    /// - Throws: `PatreonCallbackError`.
    public func code(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.map { $0.value ?? "" } }

        guard values("state") == [state] else { throw PatreonCallbackError.stateMismatch }
        if !values("error").isEmpty { throw PatreonCallbackError.denied }
        let codes = values("code")
        guard codes.count == 1, let code = codes.first, !code.isEmpty else { throw PatreonCallbackError.missingCode }
        return code
    }
}

public enum PatreonCallbackError: Error, Sendable, Equatable {
    /// The callback's `state` is missing, repeated or not this authorization's.
    case stateMismatch
    /// The person declined at Patreon.
    case denied
    /// No code, or more than one.
    case missingCode
}

/// What identity bound: the role it derived and, for a creator, the campaign.
public struct PatreonLink: Sendable, Equatable {
    public let patreonUserID: String
    public let role: PatreonAccount.Role
    /// Only for a creator.
    public let campaignID: String?

    public init(patreonUserID: String, role: PatreonAccount.Role, campaignID: String?) {
        self.patreonUserID = patreonUserID
        self.role = role
        self.campaignID = campaignID
    }
}

/// Why identity did not link, by status.
public enum PatreonLinkError: Error, Sendable, Equatable {
    /// 401, or no session token: sign in again.
    case signInRequired
    /// 409: the Patreon account is linked to another Arkavo account.
    case linkedToAnotherAccount
    /// 400: a redirect identity does not accept, or a code Patreon refused.
    case misconfigured
    /// 502: Patreon failed.
    case patreonUnavailable
    /// 503: this deployment has no Patreon.
    case notConfigured
    /// 500: identity failed.
    case serverFailure
    /// Any other status, or a 200 that is not a link.
    case unexpectedResponse
}

// MARK: - Membership

/// The Patreon account linked to the signed-in Arkavo account, as a
/// `PatreonAccountSource` reports it. A field the source does not carry is nil.
public struct PatreonAccount: Sendable, Equatable {
    public enum Role: String, Sendable {
        case consumer
        case creator
    }

    public struct Membership: Sendable, Equatable {
        public let campaignID: String
        /// Patreon's `patron_status`. Only `active_patron` entitles.
        public let patronStatus: String?
        /// The entitled tiers, as Patreon tier ids and as title slugs (two independent sets).
        public let tierIDs: [String]
        public let tierSlugs: [String]
        /// On active memberships only.
        public let campaignName: String?
        /// The Arkavo account (bare UUID) whose Patreon link owns the campaign, when exactly one does.
        public let creatorSubject: String?

        public var isActivePatron: Bool { patronStatus == "active_patron" }

        public init(
            campaignID: String,
            patronStatus: String?,
            tierIDs: [String],
            tierSlugs: [String],
            campaignName: String?,
            creatorSubject: String?
        ) {
            self.campaignID = campaignID
            self.patronStatus = patronStatus
            self.tierIDs = tierIDs
            self.tierSlugs = tierSlugs
            self.campaignName = campaignName
            self.creatorSubject = creatorSubject
        }
    }

    /// A creator's own campaign and its tier ladder, in Patreon's order.
    public struct OwnedCampaign: Sendable, Equatable {
        public let id: String
        public let name: String?
        public let tiers: [Tier]

        public init(id: String, name: String?, tiers: [Tier]) {
            self.id = id
            self.name = name
            self.tiers = tiers
        }
    }

    /// A tier of the creator's own campaign. Each field but `id` is there only when Patreon sent it.
    public struct Tier: Sendable, Equatable {
        public let id: String
        public let title: String?
        /// US cents.
        public let amountCents: Int?
        public let published: Bool?

        public init(id: String, title: String?, amountCents: Int?, published: Bool?) {
            self.id = id
            self.title = title
            self.amountCents = amountCents
            self.published = published
        }
    }

    public let role: Role
    /// The campaign a creator owns (the claim's top-level `campaign_id`).
    public let campaignID: String?
    /// The campaigns this account is a patron of.
    public let memberships: [Membership]
    /// A creator's campaign with its tier ladder; nil for a consumer, or a token minted before authnz-rs#128.
    public let ownedCampaign: OwnedCampaign?

    public var isCreator: Bool { role == .creator }

    public init(role: Role, campaignID: String?, memberships: [Membership], ownedCampaign: OwnedCampaign?) {
        self.role = role
        self.campaignID = campaignID
        self.memberships = memberships
        self.ownedCampaign = ownedCampaign
    }
}

/// Where the linked Patreon account comes from: the session token's
/// `arkavo_patreon` claim today; another source can stand in.
public protocol PatreonAccountSource: Sendable {
    /// nil when no Patreon account is linked, or the source does not say.
    func account() async throws -> PatreonAccount?
}

/// Reads the session token's `arkavo_patreon` claim (authnz-rs#128). The
/// fields #128 adds (`campaign_name`, `creator_sub`, `owned_campaign`) are
/// optional, so a token minted before it still reads. The signature is not
/// checked: the token came from identity, and resource servers verify it.
/// identity leaves the claim out when the link is missing or Patreon could not
/// be read, so no claim is no account.
public struct TokenPatreonAccountSource: PatreonAccountSource {
    private let token: @Sendable () -> String?

    public init(token: @escaping @Sendable () -> String? = { KeychainManager.getAuthenticationToken() }) {
        self.token = token
    }

    public func account() async throws -> PatreonAccount? {
        guard let token = token(), let claim = Self.patreonClaim(fromToken: token) else { return nil }
        return Self.account(from: claim)
    }

    /// The value of the one `arkavo_patreon` claim. nil when the token is not a
    /// readable CWT, or names the claim zero or several times.
    static func patreonClaim(fromToken token: String) -> CBOR? {
        var b64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }

        var reader = CBORReader(bytes: [UInt8](data))
        guard var envelope = try? reader.read(), reader.isAtEnd else { return nil }
        if case let .tag(61, inner) = envelope { envelope = inner }
        if case let .tag(18, inner) = envelope { envelope = inner }
        guard case let .array(parts) = envelope, parts.count == 4, case let .bytes(payload) = parts[2] else { return nil }

        var claimsReader = CBORReader(bytes: payload)
        guard case let .map(claims)? = try? claimsReader.read(), claimsReader.isAtEnd else { return nil }
        let values = claims.compactMap { key, value -> CBOR? in
            if case .text("arkavo_patreon") = key { return value }
            return nil
        }
        return values.count == 1 ? values[0] : nil
    }

    static func account(from claim: CBOR) -> PatreonAccount? {
        guard case let .map(fields) = claim,
              let roleName = text("role", in: fields),
              let role = PatreonAccount.Role(rawValue: roleName)
        else { return nil }

        let memberships = maps("memberships", in: fields).compactMap { entry -> PatreonAccount.Membership? in
            guard let id = text("campaign_id", in: entry) else { return nil }
            return PatreonAccount.Membership(
                campaignID: id,
                patronStatus: text("patron_status", in: entry),
                tierIDs: texts("tier_ids", in: entry),
                tierSlugs: texts("tier_slugs", in: entry),
                campaignName: text("campaign_name", in: entry),
                creatorSubject: text("creator_sub", in: entry)
            )
        }

        var ownedCampaign: PatreonAccount.OwnedCampaign?
        if case let .map(campaign)? = field("owned_campaign", in: fields), let id = text("id", in: campaign) {
            let tiers = maps("tiers", in: campaign).compactMap { tier -> PatreonAccount.Tier? in
                guard let id = text("id", in: tier) else { return nil }
                var amount: Int?
                if case let .uint(cents)? = field("amount_cents", in: tier), cents <= UInt64(Int.max) { amount = Int(cents) }
                var published: Bool?
                if case let .bool(value)? = field("published", in: tier) { published = value }
                return PatreonAccount.Tier(id: id, title: text("title", in: tier), amountCents: amount, published: published)
            }
            ownedCampaign = PatreonAccount.OwnedCampaign(id: id, name: text("name", in: campaign), tiers: tiers)
        }

        return PatreonAccount(
            role: role,
            campaignID: text("campaign_id", in: fields),
            memberships: memberships,
            ownedCampaign: ownedCampaign
        )
    }

    private static func field(_ name: String, in pairs: [(CBOR, CBOR)]) -> CBOR? {
        pairs.first { key, _ in
            if case let .text(text) = key { return text == name }
            return false
        }?.1
    }

    private static func text(_ name: String, in pairs: [(CBOR, CBOR)]) -> String? {
        if case let .text(value)? = field(name, in: pairs) { return value }
        return nil
    }

    /// The text items of an array field; other items are skipped.
    private static func texts(_ name: String, in pairs: [(CBOR, CBOR)]) -> [String] {
        guard case let .array(items)? = field(name, in: pairs) else { return [] }
        return items.compactMap { if case let .text(value) = $0 { value } else { nil } }
    }

    /// The map items of an array field; other items are skipped.
    private static func maps(_ name: String, in pairs: [(CBOR, CBOR)]) -> [[(CBOR, CBOR)]] {
        guard case let .array(items)? = field(name, in: pairs) else { return [] }
        return items.compactMap { if case let .map(entry) = $0 { entry } else { nil } }
    }
}
