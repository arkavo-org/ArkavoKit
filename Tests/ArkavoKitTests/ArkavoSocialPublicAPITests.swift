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

    /// Sign-in returns the account handle; `account` is optional so existing callers compile.
    @MainActor
    func testConnectReturnsTheHandle() {
        // Compile-time shape check only; the closure is never executed.
        let _: (ArkavoClient) async throws -> String = { (c: ArkavoClient) async throws -> String in
            try await c.connect()
        }
    }
}

/// The shape Creator's `ArkavoAuthState` declares (design sub-project C).
protocol AccountDeleting {
    @MainActor func deleteAccount(accountName: String) async throws -> AccountDeletionResult
}

extension ArkavoClient: AccountDeleting {}
