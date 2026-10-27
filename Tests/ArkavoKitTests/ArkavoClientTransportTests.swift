import XCTest
@testable import ArkavoSocial

/// The session `ArkavoClient`'s identity and profile calls go through
final class ArkavoClientTransportTests: XCTestCase {
    /// The passkey token C2PA signing sends comes from these calls; the C2PA conformance
    /// program's Level 1 (O.5) asks for TLS 1.3 on that path
    func testIdentityCallsRefuseTLSBelow1_3() {
        XCTAssertEqual(ArkavoClient.identitySession.configuration.tlsMinimumSupportedProtocolVersion, .TLSv13)
    }

    /// The Apple-link and attestation flows replay the cookie their first call set
    func testIdentityCallsUseTheSharedCookieStore() {
        XCTAssertTrue(ArkavoClient.identitySession.configuration.httpCookieStorage === HTTPCookieStorage.shared)
    }
}
