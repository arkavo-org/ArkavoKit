import AuthenticationServices
import CryptoKit
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
public class AppleSignInService: NSObject, ObservableObject {
    @Published public var isLinked: Bool = false
    @Published public var isProcessing: Bool = false
    @Published public var error: AppleSignInError?
    /// Legacy: populated only by the local-only [`linkAppleAccount()`] path.
    /// The server-verified [`linkAppleAccount(with:)`] path leaves this `nil`
    /// — Apple identity is treated as a pure authentication signal there.
    @Published public var linkedEmail: String?
    /// Legacy — see [`linkedEmail`] for the PII-posture distinction.
    @Published public var linkedName: String?

    private var authorizationController: ASAuthorizationController?
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    /// The Apple account items kept on this device.
    private let store: any AppleAccountStore

    public convenience override init() {
        self.init(store: KeychainAppleAccountStore())
    }

    /// A service over `store`: the Keychain in the app, a fake in tests.
    init(store: any AppleAccountStore) {
        self.store = store
        super.init()
        refreshLinkState()
    }

    public func refreshLinkState() {
        isLinked = store.appleUserID() != nil
        linkedEmail = store.appleEmail()
        linkedName = store.appleFullName()
    }

    /// **Legacy local-only link.** Runs Sign in with Apple with `.fullName` and
    /// `.email` scopes, captures the result to the local keychain, and never
    /// contacts the Arkavo server.
    ///
    /// Prefer [`linkAppleAccount(with:)`] for the server-verified flow that
    /// binds the Apple identity to an existing arkavo account. This method is
    /// retained for clients that still need the device-only behavior.
    public func linkAppleAccount() async throws {
        isProcessing = true
        error = nil
        defer { isProcessing = false }

        let credential = try await performAppleSignIn(nonce: nil, requestPII: true)

        try store.saveAppleUserID(credential.user)

        if let email = credential.email {
            try store.saveAppleEmail(email)
            self.linkedEmail = email
        }

        if let fullName = credential.fullName {
            let name = PersonNameComponentsFormatter().string(from: fullName)
            if !name.isEmpty {
                try store.saveAppleFullName(name)
                self.linkedName = name
            }
        }

        self.isLinked = true
    }

    /// Server-verified Apple identity link. Binds the user's Apple `sub` to
    /// their authenticated arkavo account via `POST /oauth/apple/link`.
    ///
    /// The caller must already be signed in to Arkavo — the existing CWT in
    /// the shared keychain identifies the arkavo account that the Apple
    /// identity will be bound to.
    ///
    /// **Minimum-PII**: the Apple ceremony runs with **empty scopes**. Apple
    /// will not return `email` or `fullName`, and even if a stale credential
    /// surfaces them, this method discards them. Only the opaque Apple `user`
    /// identifier is saved locally; no email/name keychain writes happen.
    ///
    /// Throws [`AppleLinkError.conflict`] if this Apple identity is already
    /// linked to a *different* arkavo account. The conflicting user_id is
    /// **not** disclosed by the server.
    public func linkAppleAccount(with client: ArkavoClient) async throws {
        isProcessing = true
        error = nil
        defer { isProcessing = false }

        // 1. Server-issued nonce. Bound to the session cookie via
        //    ArkavoClient's identity session, which both this call and step 4 share.
        let rawNonce = try await client.fetchAppleNonce()

        // 2. Per Apple guidance: the request's `nonce` is hashed by the
        //    AS framework before being embedded as the id_token's `nonce`
        //    claim. We submit the hex SHA-256 ourselves so the server can
        //    match either format (raw or hashed) — keeps the iOS-pattern
        //    contract intact.
        let hashedNonce = sha256Hex(rawNonce)

        // 3. Run the Apple ceremony. No scopes — minimum-PII posture.
        let credential = try await performAppleSignIn(nonce: hashedNonce, requestPII: false)

        guard let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8)
        else {
            throw AppleSignInError.invalidCredential
        }

        // 4. Bind on the server. Session cookie carries the nonce; CWT in
        //    X-Auth-Token (read from keychain inside the client) identifies
        //    the arkavo account. The authorization code lets the server get a
        //    refresh token it revokes when the account is deleted (TN3194).
        let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        try await client.linkAppleIdentity(idToken: identityToken, authorizationCode: authorizationCode)

        // 5. Persist only the opaque Apple userID locally so we can show
        //    "linked" state across launches. Email/name are deliberately
        //    not written, even if Apple slipped them through on a stale
        //    credential.
        try? store.saveAppleUserID(credential.user)
        self.isLinked = true
    }

    /// Unlinks every Apple ID from the signed-in Arkavo account at identity
    /// (`ArkavoClient.unlinkAppleIdentity()`), then forgets the Apple account
    /// on this device as `unlinkAppleAccount()` does. Nothing on this device
    /// changes unless identity confirms the unlink.
    ///
    /// The stored Apple user ID must go with the server link:
    /// `verifyCredentialState()` reports linked whenever Apple still
    /// authorizes it, and Apple keeps authorizing it after an unlink (no
    /// Apple token is stored on the device to revoke), so a user ID left
    /// behind shows the account as linked again on the next launch.
    ///
    /// - Throws: what `ArkavoClient.unlinkAppleIdentity()` throws.
    public func unlinkAppleAccount(with client: ArkavoClient) async throws {
        isProcessing = true
        error = nil
        defer { isProcessing = false }

        try await client.unlinkAppleIdentity()
        unlinkAppleAccount()
    }

    private func performAppleSignIn(
        nonce: String?,
        requestPII: Bool
    ) async throws -> ASAuthorizationAppleIDCredential {
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = requestPII ? [.fullName, .email] : []
        if let nonce { request.nonce = nonce }

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        authorizationController = controller

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// **Device only.** Forgets the Apple user ID, email and name stored on
    /// this device and marks the service unlinked. identity is not told: the
    /// Apple ID stays linked to the Arkavo account and can still sign in. To
    /// unlink it there too, use `unlinkAppleAccount(with:)`.
    public func unlinkAppleAccount() {
        store.deleteAppleAccount()
        isLinked = false
        linkedEmail = nil
        linkedName = nil
    }

    public func verifyCredentialState() async {
        guard let userID = store.appleUserID() else {
            isLinked = false
            return
        }

        let provider = ASAuthorizationAppleIDProvider()
        do {
            let state = try await provider.credentialState(forUserID: userID)
            switch state {
            case .authorized:
                isLinked = true
            case .revoked, .notFound:
                unlinkAppleAccount()
            case .transferred:
                break
            @unknown default:
                break
            }
        } catch {
            print("Failed to verify Apple credential state: \(error)")
        }
    }
}

extension AppleSignInService: ASAuthorizationControllerDelegate {
    public nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                let err = AppleSignInError.invalidCredential
                self.error = err
                self.continuation?.resume(throwing: err)
                self.continuation = nil
                return
            }
            // Hand the raw credential back to the caller. Keychain writes,
            // server linkage, and any PII handling are the caller's
            // responsibility — different flows want different things.
            self.continuation?.resume(returning: appleIDCredential)
            self.continuation = nil
        }
    }

    public nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            if let authError = error as? ASAuthorizationError {
                switch authError.code {
                case .canceled:
                    self.error = .userCancelled
                    self.continuation?.resume(throwing: AppleSignInError.userCancelled)
                case .failed:
                    self.error = .authorizationFailed
                    self.continuation?.resume(throwing: AppleSignInError.authorizationFailed)
                case .invalidResponse:
                    self.error = .invalidResponse
                    self.continuation?.resume(throwing: AppleSignInError.invalidResponse)
                case .notHandled:
                    self.error = .notHandled
                    self.continuation?.resume(throwing: AppleSignInError.notHandled)
                case .unknown:
                    self.error = .unknown(error)
                    self.continuation?.resume(throwing: AppleSignInError.unknown(error))
                case .notInteractive:
                    self.error = .notInteractive
                    self.continuation?.resume(throwing: AppleSignInError.notInteractive)
                case .matchedExcludedCredential:
                    self.error = .matchedExcludedCredential
                    self.continuation?.resume(throwing: AppleSignInError.matchedExcludedCredential)
                // Codes from credential import/export and passkey flows, which this service doesn't run.
                case .credentialImport, .credentialExport, .preferSignInWithApple,
                     .deviceNotConfiguredForPasskeyCreation:
                    self.error = .unknown(error)
                    self.continuation?.resume(throwing: AppleSignInError.unknown(error))
                @unknown default:
                    self.error = .unknown(error)
                    self.continuation?.resume(throwing: AppleSignInError.unknown(error))
                }
            } else {
                self.error = .unknown(error)
                self.continuation?.resume(throwing: AppleSignInError.unknown(error))
            }
            self.continuation = nil
        }
    }
}

extension AppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    public nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // AppKit and UIKit windows are main-actor only, the fallback window too. On the main
        // thread already, read them directly: `DispatchQueue.main.sync` there would trap.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { Self.currentAnchor() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { Self.currentAnchor() } }
    }

    @MainActor
    private static func currentAnchor() -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.windows.first { $0.isKeyWindow } ?? NSApplication.shared.windows.first ?? NSWindow()
        #else
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return windowScene?.windows.first { $0.isKeyWindow } ?? UIWindow()
        #endif
    }
}

/// The Apple account items `AppleSignInService` keeps on this device.
///
/// Internal, and a test seam only: `swift test` has no keychain entitlement,
/// so tests inject an in-memory store. The app always uses `KeychainAppleAccountStore`.
@MainActor
protocol AppleAccountStore {
    func appleUserID() -> String?
    func appleEmail() -> String?
    func appleFullName() -> String?
    func saveAppleUserID(_ userID: String) throws
    func saveAppleEmail(_ email: String) throws
    func saveAppleFullName(_ fullName: String) throws
    /// The user ID, email and name.
    func deleteAppleAccount()
}

/// `AppleAccountStore` over `KeychainManager`.
struct KeychainAppleAccountStore: AppleAccountStore {
    func appleUserID() -> String? { KeychainManager.getAppleUserID() }
    func appleEmail() -> String? { KeychainManager.getAppleEmail() }
    func appleFullName() -> String? { KeychainManager.getAppleFullName() }
    func saveAppleUserID(_ userID: String) throws { try KeychainManager.saveAppleUserID(userID) }
    func saveAppleEmail(_ email: String) throws { try KeychainManager.saveAppleEmail(email) }
    func saveAppleFullName(_ fullName: String) throws { try KeychainManager.saveAppleFullName(fullName) }
    func deleteAppleAccount() { KeychainManager.deleteAppleAccount() }
}

/// Why `ArkavoClient.unlinkAppleIdentity()` did not unlink
/// (`DELETE /oauth/apple/link`). Chosen by status alone: identity's bodies
/// are plain text for logs.
public enum AppleUnlinkError: Error, Sendable, Equatable {
    /// 401, or no session token: sign in again. identity also answers 401
    /// for an account that has been deleted.
    case signInRequired
    /// 429: more than 5 unlinks for this account in a minute. Try again after
    /// this many seconds: identity's `Retry-After`, or 60 when that is missing
    /// or not a number of seconds.
    case rateLimited(retryAfterSeconds: Int)
    /// 502: Apple did not revoke a token identity holds for an Apple ID, or
    /// could not be reached; that Apple ID stays linked, any other is gone.
    /// 500: identity failed (storage, a stored token it cannot read, or
    /// revocation not configured). Either way, trying again finishes the
    /// unlink, though a 500 from configuration lasts until identity is fixed.
    case serverFailure
    /// 404 or 405: this identity has no unlink route.
    case unavailable
    /// Any other status, including a success other than 204.
    case unexpectedResponse
}

/// Errors specific to the server-verified Apple identity link path
/// (`AppleSignInService.linkAppleAccount(with:)` → `POST /oauth/apple/link`).
///
/// Ceremony-side failures (user cancelled, system declined, etc.) surface as
/// [`AppleSignInError`]; these variants cover the server round trip only.
public enum AppleLinkError: Error, LocalizedError {
    /// No Arkavo CWT in the shared keychain. Caller must sign in to Arkavo
    /// before attempting to link an Apple identity.
    case missingAuthToken
    /// Server returned HTTP 400 — typically the session-stored nonce expired
    /// (10-minute TTL) or was already consumed. Caller should retry the
    /// whole flow from `fetchAppleNonce`.
    case sessionExpired
    /// Server returned HTTP 401. Most commonly the inbound `X-Auth-Token` CWT
    /// failed to verify (caller should sign back in to Arkavo), but the auth
    /// server also wraps server-internal failures (e.g. a missing DB table for
    /// the link store) as 401 — so a fresh sign-in won't always help. The
    /// `print()` logging in `linkAppleIdentity` captures the response body so
    /// the actual cause can be distinguished from the console.
    case unauthorized
    /// Server returned HTTP 409 — this Apple `sub` is already bound to a
    /// **different** arkavo account. The conflicting user_id is not
    /// disclosed; surface this to the user as "already linked elsewhere."
    case conflict
    /// Server returned an unexpected status. Includes the raw body for
    /// debugging.
    case serverError(Int, String?)
    /// Server returned 2xx but the body did not parse as expected.
    case invalidResponse
    /// URLSession or networking failure.
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .missingAuthToken:
            return "Sign in to Arkavo before linking an Apple identity."
        case .sessionExpired:
            return "The Apple sign-in session expired. Please try again."
        case .unauthorized:
            return "Your Arkavo session is no longer valid. Sign in again."
        case .conflict:
            return "This Apple ID is already linked to a different Arkavo account."
        case .serverError(let code, _):
            return "Server error (\(code)) while linking Apple identity."
        case .invalidResponse:
            return "Unexpected response from the server."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

public enum AppleSignInError: LocalizedError {
    case userCancelled
    case authorizationFailed
    case invalidResponse
    case invalidCredential
    case notHandled
    case notInteractive
    case matchedExcludedCredential
    case keychainError(Error)
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Sign in was cancelled"
        case .authorizationFailed:
            return "Authorization failed"
        case .invalidResponse:
            return "Invalid response from Apple"
        case .invalidCredential:
            return "Invalid credential received"
        case .notHandled:
            return "Authorization not handled"
        case .notInteractive:
            return "Sign in requires user interaction"
        case .matchedExcludedCredential:
            return "Credential already linked to another account"
        case .keychainError(let error):
            return "Failed to save credentials: \(error.localizedDescription)"
        case .unknown(let error):
            return "Unknown error: \(error.localizedDescription)"
        }
    }
}
