@testable import ArkavoSocial
import XCTest

/// The socket path has no seam, so `connect`'s two reuse decisions are pure
/// functions: the cached-session fast path and the already-connected shortcut.
final class ConnectTests: XCTestCase {
    private static let alice = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
    private static let bob = UUID(uuidString: "9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")!

    /// A session token of `account`'s, as identity mints one (lowercased `sub`).
    private static func token(of account: UUID) -> String {
        TestCWT.token(sub: account.uuidString.lowercased())
    }

    /// Tokens whose `sub` names no account: opaque, no `sub`, a `sub` that is not a UUID.
    private static let unreadableTokens = ["opaque-stored-token", TestCWT.tokenWithoutSub(), TestCWT.token(sub: "user-1")]

    // MARK: - The cached-session fast path

    /// A cached token without a stored handle must not "sign in" with an empty
    /// handle: the session is not reusable and the ceremony runs instead.
    func testCachedTokenWithoutAHandleRunsTheCeremony() {
        XCTAssertFalse(ArkavoClient.reusesCachedSession(token: "token", handle: nil, account: nil))
        XCTAssertFalse(ArkavoClient.reusesCachedSession(token: "token", handle: "", account: nil))
    }

    func testCachedSessionNeedsBothATokenAndAHandle() {
        XCTAssertTrue(ArkavoClient.reusesCachedSession(token: "token", handle: "alice", account: nil))
        XCTAssertFalse(ArkavoClient.reusesCachedSession(token: nil, handle: "alice", account: nil))
        XCTAssertFalse(ArkavoClient.reusesCachedSession(token: "", handle: "alice", account: nil))
        XCTAssertFalse(ArkavoClient.reusesCachedSession(token: nil, handle: nil, account: nil))
    }

    /// With no account asked for, any cached session will do, readable or not.
    func testWithoutAnAccountAnyCachedSessionIsReused() {
        for token in [Self.token(of: Self.alice), Self.token(of: Self.bob)] + Self.unreadableTokens {
            XCTAssertTrue(ArkavoClient.reusesCachedSession(token: token, handle: "alice", account: nil))
        }
    }

    /// A cached session of `account` is reused without a sheet; the `sub` is
    /// compared as a UUID, so its case does not matter.
    func testCachedSessionOfTheAccountIsReused() {
        XCTAssertTrue(ArkavoClient.reusesCachedSession(token: Self.token(of: Self.alice), handle: "alice", account: Self.alice))
        let uppercase = TestCWT.token(sub: Self.alice.uuidString.uppercased())
        XCTAssertTrue(ArkavoClient.reusesCachedSession(token: uppercase, handle: "alice", account: Self.alice))
    }

    /// bob's cached session never answers `connect(account: alice)`: it is
    /// dropped and the ceremony scoped to alice runs.
    func testCachedSessionOfAnotherAccountIsNotReused() {
        XCTAssertFalse(ArkavoClient.reusesCachedSession(token: Self.token(of: Self.bob), handle: "bob", account: Self.alice))
        XCTAssertFalse(ArkavoClient.reusesCachedSession(token: Self.token(of: Self.bob), handle: "alice", account: Self.alice))
    }

    /// A token whose account cannot be read is not that account's session.
    func testUnreadableCachedTokenIsNotReusedForAnAccount() {
        for token in Self.unreadableTokens {
            XCTAssertFalse(ArkavoClient.reusesCachedSession(token: token, handle: "alice", account: Self.alice))
        }
    }

    /// Asking for an account never makes a missing token or handle reusable.
    func testAnAccountDoesNotRescueAMissingTokenOrHandle() {
        XCTAssertFalse(ArkavoClient.reusesCachedSession(token: Self.token(of: Self.alice), handle: nil, account: Self.alice))
        XCTAssertFalse(ArkavoClient.reusesCachedSession(token: Self.token(of: Self.alice), handle: "", account: Self.alice))
        XCTAssertFalse(ArkavoClient.reusesCachedSession(token: nil, handle: "alice", account: Self.alice))
        XCTAssertFalse(ArkavoClient.reusesCachedSession(token: "", handle: "alice", account: Self.alice))
    }

    // MARK: - The already-connected shortcut

    /// Connected with no account asked for: the stored handle alone keeps the
    /// live socket, whatever the stored token.
    func testConnectedSessionIsKeptWithoutAnAccount() {
        for token in [nil, Self.token(of: Self.bob)] + Self.unreadableTokens {
            XCTAssertTrue(ArkavoClient.keepsConnectedSession(token: token, handle: "alice", account: nil))
        }
    }

    /// Connected, but no handle to return: the socket is torn down and the
    /// ceremony runs, with or without an account.
    func testConnectedSessionWithoutAHandleIsTornDown() {
        for handle in [nil, ""] {
            XCTAssertFalse(ArkavoClient.keepsConnectedSession(token: Self.token(of: Self.alice), handle: handle, account: nil))
            XCTAssertFalse(ArkavoClient.keepsConnectedSession(token: Self.token(of: Self.alice), handle: handle, account: Self.alice))
        }
    }

    func testConnectedSessionOfTheAccountIsKept() {
        XCTAssertTrue(ArkavoClient.keepsConnectedSession(token: Self.token(of: Self.alice), handle: "alice", account: Self.alice))
    }

    /// Connected as bob, `connect(account: alice)` must not answer "bob": the
    /// socket is torn down and the ceremony scoped to alice runs. So too when
    /// the stored token is gone or names no account.
    func testConnectedSessionOfAnotherAccountIsTornDown() {
        for token in [nil, Self.token(of: Self.bob)] + Self.unreadableTokens {
            XCTAssertFalse(ArkavoClient.keepsConnectedSession(token: token, handle: "bob", account: Self.alice))
        }
    }
}
