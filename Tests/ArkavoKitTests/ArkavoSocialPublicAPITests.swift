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

    /// Creator's "Unlink Apple": identity's unlink, then the device's Apple account.
    @MainActor
    func testAppleUnlinkIsPublic() {
        let _: (ArkavoClient) -> () async throws -> Void = ArkavoClient.unlinkAppleIdentity
        let _: (AppleSignInService) -> (ArkavoClient) async throws -> Void = AppleSignInService.unlinkAppleAccount(with:)
        let error: any Error = AppleUnlinkError.rateLimited(retryAfterSeconds: 30)
        guard case .rateLimited(let seconds)? = error as? AppleUnlinkError else {
            return XCTFail("AppleUnlinkError must be matchable by consumers")
        }
        XCTAssertEqual(seconds, 30)
        let _: any Sendable = AppleUnlinkError.serverFailure
        XCTAssertNotEqual(AppleUnlinkError.signInRequired, .unavailable)
        XCTAssertNotEqual(AppleUnlinkError.unexpectedResponse, .serverFailure)
    }

    /// Creator signs out of YouTube with revocation, and notices access withdrawn at Google.
    func testYouTubeSessionEndingsArePublic() {
        let _: @MainActor (YouTubeClient) async -> YouTubeRevocation = { await $0.signOut() }
        let _: (YouTubeClient) async -> Bool = { await $0.verifyAccess() }
        let _: @MainActor (YouTubeClient) -> Bool = { $0.accessWithdrawn }
        XCTAssertNotNil(YouTubeError.accessWithdrawn.errorDescription)
        XCTAssertEqual(YouTubeRevocation.failed, .failed)
    }

    /// Creator links Patreon through identity with no client secret, and reads the membership from one source.
    func testSecretlessPatreonClientIsPublic() throws {
        let client = PatreonClient(clientID: "c")
        let authorization: PatreonAuthorization = client.authorization(redirectURI: PatreonClient.defaultRedirectURI)
        XCTAssertFalse(authorization.state.isEmpty)
        let _: (PatreonAuthorization, URL) throws -> String = { try $0.code(from: $1) }
        let _: (PatreonClient) async throws -> PatreonLink = { try await $0.link(code: "c", redirectURI: "r") }
        let _: (PatreonClient) async throws -> Void = { try await $0.unlink() }
        XCTAssertEqual(PatreonUnlinkError.unavailable, .unavailable)
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

    /// The purchase path: the account StoreKit's appAccountToken names, and the transaction's submit.
    @MainActor
    func testThePurchaseCallsArePublicAndFakeable() async throws {
        // Compile-time shape checks: ArkavoClient is the real provider of both.
        let _: any AppStoreTransactionSubmitting.Type = ArkavoClient.self
        let _: any SessionAccountProviding.Type = ArkavoClient.self
        let _: (String) -> UUID? = ArkavoClient.account(ofAuthToken:)

        let fake = FakePurchases()
        let submitter: any AppStoreTransactionSubmitting = fake
        let accounts: any SessionAccountProviding = fake
        let offMain: @Sendable () async throws -> AppStoreTransactionStatus = { try await submitter.submitAppStoreTransaction("jws") }
        _ = offMain
        let status = try await submitter.submitAppStoreTransaction("jws")
        XCTAssertTrue(status.active)
        XCTAssertEqual(status.expiresAt, Date(timeIntervalSince1970: 9))
        XCTAssertEqual([status.environment, status.entitlement], ["Sandbox", "e"])
        XCTAssertFalse(status.tokenCanPublish)
        let account = await accounts.sessionAccount()
        XCTAssertNotNil(account)

        let errors: [AppStoreTransactionError] = [
            .unauthorized, .anotherAccount, .subscriptionElsewhere, .invalidTransaction, .unavailable, .serverFailure,
            .unexpectedResponse(status: 418),
        ]
        XCTAssertEqual(Set(errors.map { "\($0)" }).count, errors.count)
    }

    /// A game keeps one file that imports ArkavoSocial and fakes the rest behind `GameTokenProviding`.
    @MainActor
    func testGameTokenIsPublicAndFakeable() async throws {
        // Compile-time shape check: ArkavoClient is the real provider.
        let _: any GameTokenProviding.Type = ArkavoClient.self

        let provider: any GameTokenProviding = FakeGameTokens()
        // A game's networking is not on the main actor: the provider crosses to it.
        let offMain: @Sendable () async throws -> GameToken = { try await provider.gameToken(audience: "a") }
        _ = offMain
        let token = try await provider.gameToken(audience: "https://game.example")
        XCTAssertEqual(token.token, "fake")
        XCTAssertEqual(token.audience, "https://game.example")
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 900))
        XCTAssertTrue(token.onlinePlay)
        XCTAssertNil(token.renewedSession)

        let proof = try await provider.gameRequestProof(
            for: token, method: "GET", url: URL(string: "https://game.example/v1/war")!, body: nil
        )
        XCTAssertEqual(proof, GameRequestProof(token: "fake", timestamp: 1, signature: "sig"))
        XCTAssertEqual([proof.token, proof.signature], ["fake", "sig"])
        XCTAssertEqual(proof.timestamp, 1)

        let renewed = RenewedSession(token: "t", expiresAt: Date(timeIntervalSince1970: 1), sessionExpiresAt: Date(timeIntervalSince1970: 2))
        let withRenewal = GameToken(token: "g", audience: "a", expiresAt: Date(timeIntervalSince1970: 3), onlinePlay: false, renewedSession: renewed)
        XCTAssertEqual(withRenewal.renewedSession, renewed)

        // An app tells "sign in again" from "try later" without @testable access.
        let errors: [GameTokenError] = [
            .noSession, .sessionEnded(.idle), .unauthorized, .invalidAudience, .clockRejected,
            .rateLimited(retryAfter: 7), .unavailable, .serverFailure, .unexpectedResponse(status: 418), .invalidRequest,
        ]
        XCTAssertEqual(Set(errors.map { "\($0)" }).count, errors.count)
        guard case .rateLimited(let retryAfter) = errors[5] else { return XCTFail("rateLimited carries its wait") }
        XCTAssertEqual(retryAfter, 7)
    }
}

/// What a game's tests put in place of `ArkavoClient` for a purchase.
@MainActor
private struct FakePurchases: AppStoreTransactionSubmitting, SessionAccountProviding {
    func submitAppStoreTransaction(_: String) async throws -> AppStoreTransactionStatus {
        AppStoreTransactionStatus(active: true, expiresAt: Date(timeIntervalSince1970: 9), environment: "Sandbox",
                                  entitlement: "e", tokenCanPublish: false)
    }

    func sessionAccount() async -> UUID? { UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301") }
}

/// What a game's tests put in place of `ArkavoClient`.
@MainActor
private struct FakeGameTokens: GameTokenProviding {
    func gameToken(audience: String) async throws -> GameToken {
        GameToken(token: "fake", audience: audience, expiresAt: Date(timeIntervalSince1970: 900), onlinePlay: true)
    }

    func gameRequestProof(for token: GameToken, method _: String, url _: URL, body _: Data?) async throws -> GameRequestProof {
        GameRequestProof(token: token.token, timestamp: 1, signature: "sig")
    }
}

/// The shape Creator's `ArkavoAuthState` declares (design sub-project C).
protocol AccountDeleting {
    @MainActor func deleteAccount(accountName: String) async throws -> AccountDeletionResult
}

extension ArkavoClient: AccountDeleting {}
