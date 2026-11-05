import Foundation
import XCTest
@testable import ArkavoSocial

/// Registration's username checks and the errors identity's `GET /register/:username` refusals
/// map to (#65, #64). The client-side checks run before the App Attest preflight, so a name
/// identity would refuse spends no attestation key.
@MainActor
final class RegistrationUsernameTests: XCTestCase {
    // MARK: - The username rule (identity's `is_valid_username`)

    func testValidUsernames() {
        for name in ["a", "0", "arkavo", "my-channel-2", "apple", String(repeating: "a", count: 63)] {
            XCTAssertTrue(ArkavoClient.isValidUsername(name), name)
        }
    }

    func testInvalidUsernames() {
        let refused = [
            "", "Arkavo", "aliceBob", "-arkavo", "arkavo-", "-", "my_name", "my name", "alice.bob",
            "a/b", "a:b", "a#b", "café", "älice", " arkavo", "arkavo\n", String(repeating: "a", count: 64),
        ]
        for name in refused {
            XCTAssertFalse(ArkavoClient.isValidUsername(name), "\"\(name)\"")
        }
    }

    func testReservedUsernames() {
        XCTAssertTrue(ArkavoClient.isReservedUsername("apple-001234"))
        XCTAssertTrue(ArkavoClient.isReservedUsername("google-110248495921238986420"))
        XCTAssertFalse(ArkavoClient.isReservedUsername("apple"))
        XCTAssertFalse(ArkavoClient.isReservedUsername("pineapple-x"))
    }

    // MARK: - Checked before the preflight

    /// An unreachable identity: a regression that let the name through would fail on the network,
    /// not hang, and never with the username errors asserted here.
    private func makeClient() -> ArkavoClient {
        ArkavoClient(
            authURL: URL(string: "https://127.0.0.1:9")!,
            websocketURL: URL(string: "wss://127.0.0.1:9")!,
            relyingPartyID: "identity.arkavo.net"
        )
    }

    func testAnInvalidUsernameIsRefusedBeforeAnyRequest() async {
        do {
            _ = try await makeClient().registerUser(handle: "Arkavo", did: "did:key:z6Mktest")
            XCTFail("expected invalidUsername")
        } catch ArkavoError.invalidUsername {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAReservedUsernameIsRefusedBeforeAnyRequest() async {
        do {
            _ = try await makeClient().registerUser(handle: "apple-123", did: "did:key:z6Mktest")
            XCTFail("expected usernameUnavailable")
        } catch ArkavoError.usernameUnavailable {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - identity's refusals

    private func mapped(_ status: Int, _ body: String) -> ArkavoError? {
        ArkavoClient.registrationOptionsError(status: status, body: Data(body.utf8))
    }

    func testSuccessMapsToNoError() {
        XCTAssertNil(mapped(200, "{}"))
    }

    func testBadRequestIsAnInvalidUsername() {
        let body = "Invalid username: must be 1-63 chars of [a-z0-9-] (lowercase) with no leading/trailing hyphen"
        guard case .invalidUsername? = mapped(400, body) else { return XCTFail("400 → invalidUsername") }
    }

    func testConflictIsUnavailable() {
        guard case .usernameUnavailable? = mapped(409, "Username is not available") else {
            return XCTFail("409 → usernameUnavailable")
        }
    }

    func testAccountExistsIsUnavailable() {
        let body = "Account exists; authenticate (X-Auth-Token) to add a passkey"
        guard case .usernameUnavailable? = mapped(401, body) else { return XCTFail("401 → usernameUnavailable") }
    }

    func testReservedRefusalIsUnavailable() {
        guard case .usernameUnavailable? = mapped(403, "Username is reserved for federated identities") else {
            return XCTFail("403 reserved → usernameUnavailable")
        }
    }

    func testAttestationRequiredStaysInvalidResponse() {
        let body = "Device attestation required: call GET /device-check/register-challenge then "
            + "POST /device-check/register-attest before registering"
        guard case .invalidResponse? = mapped(403, body) else { return XCTFail("403 attestation → invalidResponse") }
    }

    func testOtherFailuresStayInvalidResponse() {
        guard case .invalidResponse? = mapped(500, "Database operation failed") else {
            return XCTFail("500 → invalidResponse")
        }
    }

    // MARK: - Readable errors

    func testNewErrorsReadAsSentences() {
        XCTAssertEqual(
            ArkavoError.invalidUsername.localizedDescription,
            "Usernames use 1 to 63 lowercase letters, numbers and hyphens, with no hyphen at the start or end."
        )
        XCTAssertEqual(
            ArkavoError.usernameUnavailable.localizedDescription,
            "That username isn't available. Try another."
        )
    }

    func testOtherErrorsKeepTheirDescriptions() {
        XCTAssertNil(ArkavoError.invalidResponse.errorDescription)
        XCTAssertNil(ArkavoError.unknownPasskey.errorDescription)
        XCTAssertNil(ArkavoError.authenticationFailed("x").errorDescription)
    }
}
