import Foundation

// The App Store purchase path (ArkavoKit #77 and #78; authnz-rs `docs/online-play-entitlement.md` and
// `src/app_store.rs` at 04a995d). An app buys with StoreKit's `appAccountToken` set to the account's
// UUID, then posts the signed transaction to identity, which binds the subscription to the account.

/// What identity answers for a submitted App Store transaction, read from the record it stored.
public struct AppStoreTransactionStatus: Sendable, Equatable {
    /// Whether the stored record grants its entitlement now.
    public let active: Bool
    /// When the subscription's current period ends.
    public let expiresAt: Date
    /// The App Store environment of the transaction: `Production` or `Sandbox`.
    public let environment: String
    /// The attribute the product grants, for example `https://arkavo.net/attr/network/value/online-play`.
    /// nil from an identity that does not name it.
    public let entitlement: String?
    /// Whether the auth token this was submitted with already carries the publishing entitlement.
    public let tokenCanPublish: Bool

    public init(active: Bool, expiresAt: Date, environment: String, entitlement: String?, tokenCanPublish: Bool) {
        self.active = active
        self.expiresAt = expiresAt
        self.environment = environment
        self.entitlement = entitlement
        self.tokenCanPublish = tokenCanPublish
    }
}

/// Why a transaction was not bound. Nothing here changes the passkey session or the stored token.
public enum AppStoreTransactionError: Error, Sendable, Equatable {
    /// No auth token is stored (nothing was sent), or identity refused it (401): renew the session or
    /// sign in, store the token, and submit again.
    case unauthorized
    /// The transaction names another live account (403): it was bought with another `appAccountToken`.
    case anotherAccount
    /// The subscription is bound to another account (409).
    case subscriptionElsewhere
    /// identity refused the transaction (422). It gives one answer for a transaction that does not
    /// verify, one that names no account, and one from an App Store environment it does not accept.
    case invalidTransaction
    /// identity takes no App Store purchases (503).
    case unavailable
    /// identity failed (500). Submitting again is safe.
    case serverFailure
    /// An answer the contract does not describe.
    case unexpectedResponse(status: Int)
}

/// The transaction submit, so an app can put a fake behind it. `ArkavoClient` is the real one.
@MainActor
public protocol AppStoreTransactionSubmitting: Sendable {
    func submitAppStoreTransaction(_ signedTransaction: String) async throws -> AppStoreTransactionStatus
}

/// The account of this app's passkey session, so an app can put a fake behind it. `ArkavoClient` is the real one.
@MainActor
public protocol SessionAccountProviding: Sendable {
    func sessionAccount() async -> UUID?
}

// The conformances are declared in ArkavoClient.swift: both protocols are Sendable, and a Sendable
// conformance must be stated in the class's own file.
extension ArkavoClient {
    /// Submits a StoreKit 2 signed transaction (`VerificationResult.jwsRepresentation`) to identity,
    /// which binds the subscription to the signed-in account and answers with its state.
    ///
    /// Buy with `appAccountToken` set to the account's UUID first: identity refuses a transaction that
    /// names no account. The call is authorized by the stored auth token and never renews the session:
    /// on `.unauthorized`, call `renewSession()` (or sign in), store the token and submit again.
    /// Submitting the same transaction again is safe.
    ///
    /// A new entitlement reaches tokens minted afterwards: a game token from `gameToken(audience:)`, or
    /// the auth token of the next renewal or sign-in.
    ///
    /// - Throws: `AppStoreTransactionError`, or the `URLError` of a request that got no answer.
    public func submitAppStoreTransaction(_ signedTransaction: String) async throws -> AppStoreTransactionStatus {
        guard !signedTransaction.isEmpty else { throw AppStoreTransactionError.invalidTransaction }
        // Without a token the post cannot be authorized, so it is not sent.
        guard let token = credentialStore.authenticationToken(), !token.isEmpty else {
            throw AppStoreTransactionError.unauthorized
        }

        var request = URLRequest(url: passkeySessionEndpoint.identity.appendingPathComponent("app-store/transactions"))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["signed_transaction": signedTransaction])

        let (data, response) = try await httpData(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // The status only: never the transaction, the token or the answer.
        print("ArkavoClient.submitAppStoreTransaction: status=\(status)")

        switch status {
        case 200:
            guard let answer = try? JSONDecoder().decode(AppStoreTransactionAnswer.self, from: data) else {
                throw AppStoreTransactionError.unexpectedResponse(status: status)
            }
            return AppStoreTransactionStatus(
                active: answer.active,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(answer.expires_at)),
                environment: answer.environment,
                entitlement: answer.entitlement,
                tokenCanPublish: answer.token_can_publish ?? false
            )
        case 401: throw AppStoreTransactionError.unauthorized
        case 403: throw AppStoreTransactionError.anotherAccount
        case 409: throw AppStoreTransactionError.subscriptionElsewhere
        case 422: throw AppStoreTransactionError.invalidTransaction
        case 500: throw AppStoreTransactionError.serverFailure
        case 503: throw AppStoreTransactionError.unavailable
        default: throw AppStoreTransactionError.unexpectedResponse(status: status)
        }
    }

    /// The account whose passkey session this app holds, or nil when it holds none: the account a
    /// game token is minted for, and the one to set StoreKit's `appAccountToken` to. It waits for a
    /// sign-in in flight.
    ///
    /// The stored auth token is shared between Arkavo apps and can come to name another account;
    /// compare with `account(ofAuthToken:)` of that token before acting for the account.
    public func sessionAccount() async -> UUID? {
        await passkeySessions.account()
    }

    /// The account an auth token names: its `sub`, as a UUID. nil when the token is unreadable or names
    /// none. The signature is not checked (identity is the verifier), so this is for matching and
    /// display, never for a decision about what the token may do.
    public nonisolated static func account(ofAuthToken token: String) -> UUID? {
        CWTSubject.sub(fromToken: token).flatMap(UUID.init(uuidString:))
    }
}

/// identity's answer, with its own member names.
private struct AppStoreTransactionAnswer: Decodable {
    let active: Bool
    let expires_at: Int64
    let environment: String
    let entitlement: String?
    let token_can_publish: Bool?
}

extension PasskeySessions {
    /// The account of the session this app holds, once any operation queued so far has finished.
    func account() async -> UUID? {
        await settled()
        return store.load().flatMap { UUID(uuidString: $0.account) }
    }
}
