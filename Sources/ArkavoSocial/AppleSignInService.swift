import AuthenticationServices
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
    @Published public var linkedEmail: String?
    @Published public var linkedName: String?

    private var authorizationController: ASAuthorizationController?
    private var continuation: CheckedContinuation<Void, Error>?

    public override init() {
        super.init()
        refreshLinkState()
    }

    public func refreshLinkState() {
        isLinked = KeychainManager.isAppleAccountLinked()
        linkedEmail = KeychainManager.getAppleEmail()
        linkedName = KeychainManager.getAppleFullName()
    }

    public func linkAppleAccount() async throws {
        isProcessing = true
        error = nil

        defer {
            isProcessing = false
        }

        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        authorizationController = controller

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            controller.performRequests()
        }
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

            let userID = appleIDCredential.user

            do {
                try KeychainManager.saveAppleUserID(userID)

                if let email = appleIDCredential.email {
                    try KeychainManager.saveAppleEmail(email)
                    self.linkedEmail = email
                }

                if let fullName = appleIDCredential.fullName {
                    let name = PersonNameComponentsFormatter().string(from: fullName)
                    if !name.isEmpty {
                        try KeychainManager.saveAppleFullName(name)
                        self.linkedName = name
                    }
                }

                self.isLinked = true
                self.continuation?.resume()
                self.continuation = nil
            } catch {
                let err = AppleSignInError.keychainError(error)
                self.error = err
                self.continuation?.resume(throwing: err)
                self.continuation = nil
            }
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
