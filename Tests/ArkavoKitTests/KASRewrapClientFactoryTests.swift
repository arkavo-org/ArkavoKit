import OpenTDFKit
import XCTest
@testable import ArkavoStreaming

final class KASRewrapClientFactoryTests: XCTestCase {
    func testLegacyRestBaseStripsTrailingKas() {
        let url = URL(string: "https://platform.arkavo.net/kas")!
        XCTAssertEqual(
            KASRewrapClientFactory.legacyRestBase(for: url),
            "https://platform.arkavo.net"
        )
    }

    func testLegacyRestBaseLeavesPlatformRoot() {
        let url = URL(string: "https://platform.arkavo.net")!
        XCTAssertEqual(
            KASRewrapClientFactory.legacyRestBase(for: url),
            "https://platform.arkavo.net"
        )
    }

    func testConfigurationUsesLegacyRewrapPath() {
        let url = URL(string: "https://platform.arkavo.net")!
        let cfg = KASRewrapClientFactory.configuration(for: url)
        XCTAssertEqual(cfg.kas?.rewrapURL, "https://platform.arkavo.net/kas/v2/rewrap")
        XCTAssertEqual(cfg.kas?.publicKeyURL, "https://platform.arkavo.net/kas/v2/kas_public_key")
    }

    func testConfigurationFromKasSuffixedURLMatchesOldAppendRewrap() {
        let url = URL(string: "https://100.arkavo.net/kas")!
        let cfg = KASRewrapClientFactory.configuration(for: url)
        XCTAssertEqual(cfg.kas?.rewrapURL, "https://100.arkavo.net/kas/v2/rewrap")
    }
}
