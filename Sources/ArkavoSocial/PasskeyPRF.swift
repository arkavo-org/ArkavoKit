import AuthenticationServices
import CryptoKit
import Foundation
import Security

// The passkey PRF assertion (ArkavoKit#73, arkavo-ios owner-KAS design §4.7). A passkey assertion with the
// WebAuthn `prf` extension, under user verification, against the owner's identity credential. Its challenge
// is local and random: the assertion unlocks something on this device and is never sent anywhere. The PRF
// output stays inside ArkavoKit: callers hand it to `OwnerKASVault` and never see its bytes.

/// The first PRF output of one passkey assertion, and what it was evaluated for.
///
/// Its bytes are not public and never print, dump or encode: pass it to `OwnerKASVault.seal(_:with:binding:)`
/// or `OwnerKASVault.open(with:binding:)`. Holding it unlocks the vault it came from, so drop it once that
/// is done.
public struct PasskeyPRFOutput: Sendable {
    /// The passkey that answered.
    public let credentialID: Data
    /// The relying party the passkey belongs to.
    public let relyingPartyID: String
    /// The PRF input the output was evaluated at (WebAuthn `prf.eval.first`).
    public let input: Data
    /// The passkey's user handle, so a caller can check whose passkey was picked.
    public let userID: Data?
    /// The PRF output (32 bytes from the platform authenticator).
    let key: SymmetricKey

    init(credentialID: Data, relyingPartyID: String, input: Data, userID: Data?, key: SymmetricKey) {
        self.credentialID = credentialID
        self.relyingPartyID = relyingPartyID
        self.input = input
        self.userID = userID
        self.key = key
    }
}

extension PasskeyPRFOutput: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "PasskeyPRFOutput(credentialID: \(credentialID.base64URLEncodedString()), relyingPartyID: \(relyingPartyID), output: <redacted>)"
    }

    public var debugDescription: String {
        description
    }

    /// No children, so `dump` and reflection show nothing of the output.
    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}

/// Why a passkey PRF assertion gave no output. Nothing was sealed or opened.
public enum PasskeyPRFError: Error, Sendable, Equatable {
    /// The person cancelled the passkey sheet.
    case cancelled
    /// The passkey answered without a PRF output: its provider, or the device that holds it (a phone reached
    /// by QR code, a security key), does not evaluate PRF. This is the only way the platform tells: there is
    /// no check that runs without a passkey sheet.
    case unsupported
    /// A passkey other than the listed ones answered.
    case wrongCredential
}

/// What the passkey sheet returned for a PRF assertion.
struct PRFAssertionResult: Sendable {
    let credentialID: Data
    let userID: Data?
    let prf: SymmetricKey?
}

public extension ArkavoClient {
    /// A passkey assertion with the PRF extension, for a local secret. User verification is required (see
    /// `passkeyUserVerification`), the challenge is 32 local random bytes, and nothing is sent to identity.
    ///
    /// This is also the support check: there is no way to ask whether a passkey evaluates PRF without its
    /// sheet. Setting up a vault (`sealOwnerKASVault(_:binding:allowedCredentialIDs:)`) asks once and throws
    /// `PasskeyPRFError.unsupported` before anything is sealed.
    ///
    /// - Parameters:
    ///   - input: the PRF input. A new vault uses `OwnerKASVault.newPRFInput()`; an existing one its `prfInput`.
    ///   - allowedCredentialIDs: the passkeys the sheet may offer. Empty offers every passkey for the relying party.
    /// - Throws: `PasskeyPRFError.cancelled`, `.unsupported` or `.wrongCredential`; any other
    ///   `ASAuthorizationError` from the sheet unchanged.
    func passkeyPRF(input: Data, allowedCredentialIDs: [Data] = []) async throws -> PasskeyPRFOutput {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyID)
        let request = Self.passkeyPRFRequest(
            provider: provider,
            challenge: secureRandomBytes(32),
            input: input,
            allowedCredentialIDs: allowedCredentialIDs
        )

        let result: PRFAssertionResult
        do {
            result = try await prfAssertionProvider(request)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            throw PasskeyPRFError.cancelled
        }

        if !allowedCredentialIDs.isEmpty, !allowedCredentialIDs.contains(result.credentialID) {
            throw PasskeyPRFError.wrongCredential
        }
        guard let output = result.prf else {
            throw PasskeyPRFError.unsupported
        }
        return PasskeyPRFOutput(
            credentialID: result.credentialID,
            relyingPartyID: relyingPartyID,
            input: input,
            userID: result.userID,
            key: output
        )
    }

    /// The PRF assertion that opens `vault`: its passkey only, at its PRF input.
    ///
    /// - Throws: `OwnerKASVaultError.wrongPasskey`, without a sheet, when the vault's passkey belongs to
    ///   another relying party than this client's; otherwise as `passkeyPRF(input:allowedCredentialIDs:)`.
    func passkeyPRF(for vault: OwnerKASVault) async throws -> PasskeyPRFOutput {
        guard vault.relyingPartyID == relyingPartyID else {
            throw OwnerKASVaultError.wrongPasskey
        }
        return try await passkeyPRF(input: vault.prfInput, allowedCredentialIDs: [vault.credentialID])
    }

    /// Sets up an owner-KAS vault: one passkey sheet with a new PRF input, then `secret` sealed under its
    /// output. The vault records the passkey that answered, and only that passkey opens it.
    ///
    /// Store the result (`encoded()`) where the app keeps the vault; ArkavoKit keeps nothing.
    ///
    /// - Parameter allowedCredentialIDs: the owner's passkeys, when the app knows them. Empty offers every
    ///   passkey for the relying party.
    /// - Throws: `PasskeyPRFError.unsupported` when the passkey gives no PRF output, and `.cancelled` when
    ///   the sheet is cancelled. Either way nothing is sealed.
    func sealOwnerKASVault(
        _ secret: Data,
        binding: OwnerKASVaultBinding,
        allowedCredentialIDs: [Data] = []
    ) async throws -> OwnerKASVault {
        let prf = try await passkeyPRF(input: OwnerKASVault.newPRFInput(), allowedCredentialIDs: allowedCredentialIDs)
        return try OwnerKASVault.seal(secret, with: prf, binding: binding)
    }

    /// Unlocks an owner-KAS vault: one passkey sheet for the vault's passkey, then the secret.
    ///
    /// A cancelled or unsupported assertion leaves the vault locked; nothing falls back.
    ///
    /// - Throws: `PasskeyPRFError` from the sheet; `OwnerKASVaultError.cannotOpen` when the binding is not
    ///   the one it was sealed with or the vault was altered.
    func openOwnerKASVault(_ vault: OwnerKASVault, binding: OwnerKASVaultBinding) async throws -> Data {
        let prf = try await passkeyPRF(for: vault)
        return try vault.open(with: prf, binding: binding)
    }
}

extension ArkavoClient {
    /// The PRF assertion request. User verification is always `required` (see `passkeyUserVerification`).
    nonisolated static func passkeyPRFRequest(
        provider: ASAuthorizationPlatformPublicKeyCredentialProvider,
        challenge: Data,
        input: Data,
        allowedCredentialIDs: [Data]
    ) -> ASAuthorizationPlatformPublicKeyCredentialAssertionRequest {
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = allowedCredentialIDs.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }
        request.userVerificationPreference = passkeyUserVerification
        request.prf = .inputValues(.saltInput1(input))
        return request
    }
}

/// `count` bytes from the system's secure random generator.
func secureRandomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    return Data(bytes)
}
