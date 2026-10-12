import AuthenticationServices
import XCTest
@testable import ArkavoSocial

/// The passkey sheet must offer only the account being signed in to (or deleted):
/// the request carries the credential ids the server's options listed for it.
final class PasskeyAssertionRequestTests: XCTestCase {
    private let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
        relyingPartyIdentifier: "identity.arkavo.net"
    )
    private let challenge = Data("challenge".utf8)

    func testRequestIsLimitedToTheListedCredentials() {
        // 0xFB 0xFF 0x01 is "-_8B" in base64url (needs both URL-safe substitutions);
        // 0x01 0x02 is "AQI" (needs padding).
        let request = ArkavoClient.passkeyAssertionRequest(
            provider: provider,
            challenge: challenge,
            allowCredentialIDs: ["-_8B", "AQI"]
        )

        XCTAssertEqual(
            request.allowedCredentials.map(\.credentialID),
            [Data([0xFB, 0xFF, 0x01]), Data([0x01, 0x02])]
        )
        XCTAssertEqual(request.challenge, challenge)
    }

    func testNoListedCredentialsLeavesTheRequestOpen() {
        let request = ArkavoClient.passkeyAssertionRequest(
            provider: provider,
            challenge: challenge,
            allowCredentialIDs: []
        )

        XCTAssertTrue(request.allowedCredentials.isEmpty)
    }

    func testAnUndecodableIDIsSkipped() {
        let request = ArkavoClient.passkeyAssertionRequest(
            provider: provider,
            challenge: challenge,
            allowCredentialIDs: ["AQI", "not base64url!"]
        )

        XCTAssertEqual(request.allowedCredentials.map(\.credentialID), [Data([0x01, 0x02])])
    }

    func testOnlyPublicKeyCredentialsAreListed() throws {
        let listed = try JSONDecoder().decode(AuthenticationOptionsResponse.self, from: Data(#"""
        {"publicKey": {"challenge": "Y2hhbGxlbmdl",
          "allowCredentials": [{"id": "AQI", "type": "public-key"}, {"id": "AwQ", "type": "other"}]}}
        """#.utf8))
        XCTAssertEqual(listed.publicKey.publicKeyCredentialIDs, ["AQI"])

        let none = try JSONDecoder().decode(
            AuthenticationOptionsResponse.self,
            from: Data(#"{"publicKey": {"challenge": "Y2hhbGxlbmdl"}}"#.utf8)
        )
        XCTAssertEqual(none.publicKey.publicKeyCredentialIDs, [])
    }
}
