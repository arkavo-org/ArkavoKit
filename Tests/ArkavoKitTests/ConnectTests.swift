@testable import ArkavoSocial
import XCTest

/// The socket path has no seam, so the fast-path decision is a pure function.
final class ConnectTests: XCTestCase {
    /// A cached token without a stored handle must not "sign in" with an empty
    /// handle: the session is not reusable and the ceremony runs instead.
    func testCachedTokenWithoutAHandleRunsTheCeremony() {
        XCTAssertFalse(ArkavoClient.usesCachedSession(token: "token", handle: nil))
        XCTAssertFalse(ArkavoClient.usesCachedSession(token: "token", handle: ""))
    }

    func testCachedSessionNeedsBothATokenAndAHandle() {
        XCTAssertTrue(ArkavoClient.usesCachedSession(token: "token", handle: "alice"))
        XCTAssertFalse(ArkavoClient.usesCachedSession(token: nil, handle: "alice"))
        XCTAssertFalse(ArkavoClient.usesCachedSession(token: "", handle: "alice"))
        XCTAssertFalse(ArkavoClient.usesCachedSession(token: nil, handle: nil))
    }
}
