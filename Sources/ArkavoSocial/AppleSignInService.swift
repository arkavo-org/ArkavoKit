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

    public override init() {
        super.init()
        refreshLinkState()
    }

    public func refreshLinkState() {
        isLinked = KeychainManager.isAppleAccountLinked()
        linkedEmail = KeychainManager.getAppleEmail()
        linkedName = KeychainManager.getAppleFullName()
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

        try KeychainManager.saveAppleUserID(credential.user)

        if let email = credential.email {
            try KeychainManager.saveAppleEmail(email)
            self.linkedEmail = email
        }

        if let fullName = credential.fullName {
            let name = PersonNameComponentsFormatter().string(from: fullName)
            if !name.isEmpty {
                try KeychainManager.saveAppleFullName(name)
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
        //    URLSession.shared, which both this call and step 4 share.
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
        //    the arkavo account.
        try await client.linkAppleIdentity(idToken: identityToken)

        // 5. Persist only the opaque Apple userID locally so we can show
        //    "linked" state across launches. Email/name are deliberately
        //    not written, even if Apple slipped them through on a stale
        //    credential.
        try? KeychainManager.saveAppleUserID(credential.user)
        self.isLinked = true
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

    public func unlinkAppleAccount() {
        KeychainManager.deleteAppleAccount()
        isLinked = false
        linkedEmail = nil
        linkedName = nil
    }

    public func verifyCredentialState() async {
        guard let userID = KeychainManager.getAppleUserID() else {
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
        #if os(macOS)
        var window: NSWindow?
        DispatchQueue.main.sync {
            window = NSApplication.shared.windows.first { $0.isKeyWindow } ?? NSApplication.shared.windows.first
        }
        return window ?? NSWindow()
        #else
        var window: UIWindow?
        DispatchQueue.main.sync {
            let scenes = UIApplication.shared.connectedScenes
            let windowScene = scenes.first as? UIWindowScene
            window = windowScene?.windows.first { $0.isKeyWindow }
        }
        return window ?? UIWindow()
        #endif
    }
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
    /// Server returned HTTP 401 — the inbound `X-Auth-Token` CWT failed to
    /// verify. Caller should sign back in to Arkavo.
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
