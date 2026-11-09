import AuthenticationServices
import CryptoKit
import XCTest
@testable import ArkavoSocial

/// The passkey PRF assertion (ArkavoKit#73): a local ceremony under user verification that is never sent
/// anywhere, and the owner-KAS vault's seal and unlock on top of it.
@MainActor
final class PasskeyPRFTests: XCTestCase {
    private static let credentialID = Data([0xC0, 0xFF, 0xEE])
    private static let binding = OwnerKASVaultBinding(
        vaultID: "01JC9Z3M6V0F7Q8R2S4T6W8Y0A",
        ownerSubject: "0a1b2c3d-0000-4000-8000-000000000001",
        kasKeyID: "kas-1",
        algorithm: "ec:secp256r1"
    )
    private static let secret = Data("two P-256 private keys".utf8)

    private var client: ArkavoClient!
    private var authenticator: SimulatedPRFAuthenticator!

    override func setUp() async throws {
        client = makeTestClient()
        authenticator = SimulatedPRFAuthenticator(credentialID: Self.credentialID)
        client.prfAssertionProvider = authenticator.perform
        // The PRF ceremony never reaches identity.
        client.httpData = { request in
            XCTFail("unexpected request to \(request.url?.absoluteString ?? "?")")
            throw URLError(.notConnectedToInternet)
        }
    }

    private func assertThrows<E: Error & Equatable, T>(
        _ expected: E,
        _ call: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await call()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, "got \(error)", file: file, line: line)
        }
    }

    // MARK: - The request

    func testTheRequestRequiresVerificationAndCarriesTheInput() async throws {
        let input = Data(repeating: 0x11, count: 32)

        _ = try await client.passkeyPRF(input: input, allowedCredentialIDs: [Self.credentialID])

        let request = try XCTUnwrap(authenticator.requests.first)
        XCTAssertEqual(request.userVerificationPreference, .required)
        XCTAssertEqual(request.prf?.inputValues?.saltInput1, input)
        XCTAssertNil(request.prf?.inputValues?.saltInput2)
        XCTAssertEqual(request.allowedCredentials.map(\.credentialID), [Self.credentialID])
        XCTAssertEqual(request.relyingPartyIdentifier, "identity.example.test")
    }

    func testEachAssertionHasAFreshLocalChallenge() async throws {
        let input = Data(repeating: 0x11, count: 32)

        _ = try await client.passkeyPRF(input: input)
        _ = try await client.passkeyPRF(input: input)

        let challenges = authenticator.requests.map(\.challenge)
        XCTAssertEqual(challenges.map(\.count), [32, 32])
        XCTAssertNotEqual(challenges[0], challenges[1])
    }

    func testWithNoListedPasskeyTheSheetOffersEvery() async throws {
        _ = try await client.passkeyPRF(input: Data([1]))

        XCTAssertEqual(authenticator.requests.first?.allowedCredentials.isEmpty, true)
    }

    // MARK: - The answer

    func testTheOutputNamesThePasskeyAndTheInput() async throws {
        let input = Data(repeating: 0x11, count: 32)

        let output = try await client.passkeyPRF(input: input)

        XCTAssertEqual(output.credentialID, Self.credentialID)
        XCTAssertEqual(output.relyingPartyID, "identity.example.test")
        XCTAssertEqual(output.input, input)
        XCTAssertEqual(output.userID, Data("owner".utf8))
    }

    func testNoPRFOutputIsUnsupported() async {
        authenticator.supportsPRF = false

        await assertThrows(PasskeyPRFError.unsupported) { try await self.client.passkeyPRF(input: Data([1])) }
    }

    func testACancelledSheetIsCancelled() async {
        authenticator.error = ASAuthorizationError(.canceled)

        await assertThrows(PasskeyPRFError.cancelled) { try await self.client.passkeyPRF(input: Data([1])) }
    }

    func testOtherSheetErrorsAreUnchanged() async {
        authenticator.error = ASAuthorizationError(.failed)

        do {
            _ = try await client.passkeyPRF(input: Data([1]))
            XCTFail("expected the sheet's error")
        } catch let error as ASAuthorizationError {
            XCTAssertEqual(error.code, .failed)
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testAPasskeyOutsideTheListedOnesIsRefused() async {
        await assertThrows(PasskeyPRFError.wrongCredential) {
            try await self.client.passkeyPRF(input: Data([1]), allowedCredentialIDs: [Data([0x01])])
        }
    }

    // MARK: - The owner-KAS vault

    func testANewVaultAsksOnceAndUnlocksWithTheSamePasskey() async throws {
        let vault = try await client.sealOwnerKASVault(Self.secret, binding: Self.binding)

        XCTAssertEqual(authenticator.requests.count, 1)
        XCTAssertEqual(vault.credentialID, Self.credentialID)
        XCTAssertEqual(vault.prfInput.count, 32)

        let opened = try await client.openOwnerKASVault(vault, binding: Self.binding)

        XCTAssertEqual(opened, Self.secret)
        let unlock = try XCTUnwrap(authenticator.requests.last)
        XCTAssertEqual(unlock.allowedCredentials.map(\.credentialID), [Self.credentialID])
        XCTAssertEqual(unlock.prf?.inputValues?.saltInput1, vault.prfInput)
        XCTAssertEqual(unlock.userVerificationPreference, .required)
    }

    func testEveryNewVaultHasItsOwnPRFInput() async throws {
        let first = try await client.sealOwnerKASVault(Self.secret, binding: Self.binding)
        let second = try await client.sealOwnerKASVault(Self.secret, binding: Self.binding)

        XCTAssertNotEqual(first.prfInput, second.prfInput)
    }

    func testANewVaultCanBeLimitedToTheOwnersPasskeys() async throws {
        _ = try await client.sealOwnerKASVault(Self.secret, binding: Self.binding, allowedCredentialIDs: [Self.credentialID])

        XCTAssertEqual(authenticator.requests.first?.allowedCredentials.map(\.credentialID), [Self.credentialID])
    }

    func testUnsupportedPRFSealsNothing() async {
        authenticator.supportsPRF = false

        await assertThrows(PasskeyPRFError.unsupported) {
            try await self.client.sealOwnerKASVault(Self.secret, binding: Self.binding)
        }
    }

    func testACancelledUnlockLeavesTheVaultLocked() async throws {
        let vault = try await client.sealOwnerKASVault(Self.secret, binding: Self.binding)
        authenticator.error = ASAuthorizationError(.canceled)

        await assertThrows(PasskeyPRFError.cancelled) {
            try await self.client.openOwnerKASVault(vault, binding: Self.binding)
        }
    }

    func testAnUnlockThatLostPRFLeavesTheVaultLocked() async throws {
        let vault = try await client.sealOwnerKASVault(Self.secret, binding: Self.binding)
        authenticator.supportsPRF = false

        await assertThrows(PasskeyPRFError.unsupported) {
            try await self.client.openOwnerKASVault(vault, binding: Self.binding)
        }
    }

    func testAVaultOfAnotherRelyingPartyAsksNothing() async throws {
        var vault = try await client.sealOwnerKASVault(Self.secret, binding: Self.binding)
        vault.relyingPartyID = "other.example.test"
        let asked = authenticator.requests.count

        await assertThrows(OwnerKASVaultError.wrongPasskey) {
            try await self.client.openOwnerKASVault(vault, binding: Self.binding)
        }
        XCTAssertEqual(authenticator.requests.count, asked)
    }

    func testAnotherOwnersBindingCannotOpen() async throws {
        let vault = try await client.sealOwnerKASVault(Self.secret, binding: Self.binding)
        let other = OwnerKASVaultBinding(
            vaultID: Self.binding.vaultID,
            ownerSubject: "someone-else",
            kasKeyID: Self.binding.kasKeyID,
            algorithm: Self.binding.algorithm
        )

        await assertThrows(OwnerKASVaultError.cannotOpen) {
            try await self.client.openOwnerKASVault(vault, binding: other)
        }
    }
}

/// A platform authenticator: one passkey whose PRF is HMAC-SHA-256 under a secret of its own, like a real
/// credential's (WebAuthn `prf` over CTAP `hmac-secret`).
@MainActor
final class SimulatedPRFAuthenticator {
    let credentialID: Data
    var supportsPRF = true
    var error: Error?
    private(set) var requests: [ASAuthorizationPlatformPublicKeyCredentialAssertionRequest] = []
    private let credentialSecret = SymmetricKey(size: .bits256)

    init(credentialID: Data) {
        self.credentialID = credentialID
    }

    func perform(_ request: ASAuthorizationPlatformPublicKeyCredentialAssertionRequest) async throws -> PRFAssertionResult {
        requests.append(request)
        if let error {
            throw error
        }
        guard supportsPRF, let input = request.prf?.inputValues?.saltInput1 else {
            return PRFAssertionResult(credentialID: credentialID, userID: Data("owner".utf8), prf: nil)
        }
        let output = HMAC<SHA256>.authenticationCode(for: input, using: credentialSecret)
        return PRFAssertionResult(
            credentialID: credentialID,
            userID: Data("owner".utf8),
            prf: SymmetricKey(data: Data(output))
        )
    }
}
