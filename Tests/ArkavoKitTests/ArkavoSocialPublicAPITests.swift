import ArkavoSocial
import XCTest

/// Consumers (the Arkavo viewer) match these errors without @testable access.
final class ArkavoSocialPublicAPITests: XCTestCase {
    func testArkavoErrorIsPublicAndMatchable() {
        let error: any Error = ArkavoError.authenticationFailed("User Not Found")
        guard case ArkavoError.authenticationFailed(let message)? = error as? ArkavoError else {
            return XCTFail("ArkavoError must be matchable by consumers")
        }
        XCTAssertEqual(message, "User Not Found")
    }

    /// Creator wraps the client in a protocol of its own to fake it in tests.
    func testAccountDeletionIsPublicAndFakeable() {
        let requestedAt = Date(timeIntervalSince1970: 0)
        let completesBy = Date(timeIntervalSince1970: 300)
        let receipt = AccountDeletionReceipt(deletionID: "d", requestedAt: requestedAt, completesBy: completesBy)

        XCTAssertEqual(receipt.deletionID, "d")
        XCTAssertEqual(receipt.requestedAt, requestedAt)
        XCTAssertEqual(receipt.completesBy, completesBy)
        XCTAssertEqual(AccountDeletionResult.deleted(receipt), .deleted(receipt))
        XCTAssertNotEqual(AccountDeletionResult.deleted(nil), .alreadyDeleted)

        // Compile-time shape check: ArkavoClient satisfies the protocol below.
        let _: any AccountDeleting.Type = ArkavoClient.self
    }

    @MainActor
    func testAppleLinkTakesAnAuthorizationCode() {
        // Compile-time shape check: the two-argument overload is public.
        let _: (ArkavoClient) -> (String, String?) async throws -> Void = ArkavoClient.linkAppleIdentity(idToken:authorizationCode:)
    }

    /// Apps map a passkey the server does not know to a "create an account" path.
    func testUnknownPasskeyIsMatchable() {
        let error: any Error = ArkavoError.unknownPasskey
        var matched = false
        switch error as? ArkavoError {
        case .unknownPasskey?:
            matched = true
        default:
            break
        }
        XCTAssertTrue(matched, "ArkavoError.unknownPasskey must be matchable by consumers")
    }

    /// Apps renew their passkey session and map every refusal to a passkey sign-in.
    @MainActor
    func testPasskeySessionIsPublicAndMatchable() {
        // Compile-time shape checks only; the closures are never executed.
        let _: (ArkavoClient) async throws -> RenewedSession = { try await $0.renewSession() }
        let _: (ArkavoClient) async -> Void = { await $0.endSession() }

        let renewed = RenewedSession(token: "t", expiresAt: Date(timeIntervalSince1970: 1), sessionExpiresAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(renewed.token, "t")
        XCTAssertEqual(renewed.expiresAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(renewed.sessionExpiresAt, Date(timeIntervalSince1970: 2))

        let errors: [any Error] = [
            PasskeySessionError.noSession,
            PasskeySessionError.sessionEnded(.reused),
            PasskeySessionError.serverFailure,
        ]
        let signIns = errors.filter { error in
            switch error as? PasskeySessionError {
            case .noSession?, .sessionEnded?: true
            default: false
            }
        }
        XCTAssertEqual(signIns.count, 2)
        XCTAssertEqual(SessionEndReason(rawValue: "account_deleted"), .accountDeleted)
    }

    /// Creator links Patreon through identity with no client secret, and reads the membership from one source.
    func testSecretlessPatreonClientIsPublic() throws {
        let client = PatreonClient(clientID: "c")
        let authorization: PatreonAuthorization = client.authorization(redirectURI: PatreonClient.defaultRedirectURI)
        XCTAssertFalse(authorization.state.isEmpty)
        let _: (PatreonAuthorization, URL) throws -> String = { try $0.code(from: $1) }
        let _: (PatreonClient) async throws -> PatreonLink = { try await $0.link(code: "c", redirectURI: "r") }
        let _: () -> Void = { PatreonClient.removeLegacyTokens() }

        let source: any PatreonAccountSource = TokenPatreonAccountSource(token: { nil })
        XCTAssertNotNil(source)
        let account = PatreonAccount(
            role: .creator,
            campaignID: "1",
            memberships: [.init(campaignID: "2", patronStatus: nil, tierIDs: [], tierSlugs: [], campaignName: "n", creatorSubject: "s")],
            ownedCampaign: .init(id: "1", name: nil, tiers: [.init(id: "t", title: "Gold", amountCents: 500, published: true)])
        )
        XCTAssertTrue(account.isCreator)

        for error in [PatreonLinkError.signInRequired, .linkedToAnotherAccount, .misconfigured, .patreonUnavailable,
                      .notConfigured, .serverFailure, .unexpectedResponse] {
            XCTAssertNotNil(error as any Error)
        }
        XCTAssertEqual(PatreonCallbackError.stateMismatch, .stateMismatch)
    }

    /// Sign-in returns the account handle; `account` is optional so existing callers compile.
    @MainActor
    func testConnectReturnsTheHandle() {
        // Compile-time shape check only; the closure is never executed.
        let _: (ArkavoClient) async throws -> String = { (c: ArkavoClient) async throws -> String in
            try await c.connect()
        }
    }

    /// arkavo-ios's `OwnerKASVaultUnlocking` seam: seal at setup, unlock, and tell cancelled from unsupported.
    @MainActor
    func testTheOwnerKASVaultIsPublic() throws {
        let binding = OwnerKASVaultBinding(vaultID: "v", ownerSubject: "s", kasKeyID: "k", algorithm: "ec:secp256r1")
        XCTAssertEqual(binding.vaultID, "v")

        // Compile-time shape checks only; the closures are never executed.
        let _: (ArkavoClient) async throws -> OwnerKASVault = { c in
            try await c.sealOwnerKASVault(Data(), binding: binding, allowedCredentialIDs: [])
        }
        let _: (ArkavoClient, OwnerKASVault) async throws -> Data = { c, vault in
            try await c.openOwnerKASVault(vault, binding: binding)
        }
        let _: (ArkavoClient, OwnerKASVault) async throws -> (PasskeyPRFOutput, Data) = { c, vault in
            let prf = try await c.passkeyPRF(for: vault)
            let resealed = try OwnerKASVault.seal(Data(), with: prf, binding: binding)
            return try (prf, resealed.open(with: prf, binding: binding))
        }
        let _: (ArkavoClient) async throws -> PasskeyPRFOutput = { c in
            try await c.passkeyPRF(input: OwnerKASVault.newPRFInput(), allowedCredentialIDs: [])
        }
        let _: (OwnerKASVault) throws -> OwnerKASVault = { try OwnerKASVault(encoded: $0.encoded()) }

        let errors: [any Error] = [PasskeyPRFError.cancelled, PasskeyPRFError.unsupported, PasskeyPRFError.wrongCredential]
        XCTAssertEqual(errors.compactMap { $0 as? PasskeyPRFError }.count, 3)
        for error in [OwnerKASVaultError.wrongPasskey, .cannotOpen, .unsupportedVersion(2), .malformed] {
            XCTAssertNotNil(error as any Error)
        }
    }
}

/// The shape Creator's `ArkavoAuthState` declares (design sub-project C).
protocol AccountDeleting {
    @MainActor func deleteAccount(accountName: String) async throws -> AccountDeletionResult
}

extension ArkavoClient: AccountDeleting {}
