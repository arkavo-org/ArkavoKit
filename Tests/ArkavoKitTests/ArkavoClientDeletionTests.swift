import AuthenticationServices
import XCTest
@testable import ArkavoSocial

/// `deleteAccount(accountName:)`: the ceremony, the request, its retries and
/// its refusals. What it removes from the device is in ArkavoClientDeletionWipeTests.
@MainActor
final class ArkavoClientDeletionTests: XCTestCase {
    private static let receiptBody =
        #"{"deletion_id":"del-secret","status":"pending","requested_at":1760000000,"completes_by":1760000300}"#
    private static let userNotFound = ArkavoError.authenticationFailed("User Not Found")

    private var harness: DeletionHarness!
    private var client: ArkavoClient { harness.client }

    override func setUp() async throws {
        harness = DeletionHarness()
    }

    private func assertDeletionFailed(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case let ArkavoError.authenticationFailed(message)? = error as? ArkavoError else {
            return XCTFail("expected authenticationFailed, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(message, "Account deletion failed", file: file, line: line)
    }

    private func assertRefused(_ call: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await call()
            XCTFail("expected invalidState", file: file, line: line)
        } catch ArkavoError.invalidState {
            // expected
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }

    // MARK: - Server answers

    func testAcceptedDeletionReturnsTheReceipt() async throws {
        harness.stubCeremonies([.success("fresh-token")])
        harness.stubHTTP([.status(202, Self.receiptBody)])

        let result = try await client.deleteAccount(accountName: "alice")

        XCTAssertEqual(result, .deleted(AccountDeletionReceipt(
            deletionID: "del-secret",
            requestedAt: Date(timeIntervalSince1970: 1_760_000_000),
            completesBy: Date(timeIntervalSince1970: 1_760_000_300)
        )))
    }

    func testUndecodableSuccessStillCountsAsDeleted() async throws {
        harness.stubCeremonies([.success("fresh-token")])
        harness.stubHTTP([.status(202, "<html>accepted</html>")])

        let result = try await client.deleteAccount(accountName: "alice")

        XCTAssertEqual(result, .deleted(nil))
    }

    func testReceiptWithTextTimestampsDecodesToNil() async throws {
        harness.stubCeremonies([.success("fresh-token")])
        harness.stubHTTP([.status(202, #"{"deletion_id":"d","requested_at":"2026-10-11T00:00:00Z","completes_by":"2026-10-11T00:05:00Z"}"#)])

        let result = try await client.deleteAccount(accountName: "alice")

        XCTAssertEqual(result, .deleted(nil))
    }

    func testRequestCarriesTheFreshTokenNotTheStoredOne() async throws {
        harness.store.token = "stored-token"
        harness.stubCeremonies([.success("fresh-token")])
        let http = harness.stubHTTP([.status(202, Self.receiptBody)])

        _ = try await client.deleteAccount(accountName: "alice")

        XCTAssertEqual(harness.ceremonies, ["alice"])
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.absoluteString, "https://identity.example.test/account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Token"), "fresh-token")
    }

    func testConflictIsRetriedOnceWithTheSameToken() async throws {
        harness.stubCeremonies([.success("fresh-token")])
        let http = harness.stubHTTP([.status(409, "{}"), .status(202, Self.receiptBody)])

        let result = try await client.deleteAccount(accountName: "alice")

        guard case .deleted(.some) = result else { return XCTFail("expected a receipt, got \(result)") }
        XCTAssertEqual(http.requests.map { $0.value(forHTTPHeaderField: "X-Auth-Token") }, ["fresh-token", "fresh-token"])
        XCTAssertEqual(harness.ceremonies.count, 1, "a conflict needs no new sign-in")
    }

    func testTwoConflictsThrow() async {
        harness.stubCeremonies([.success("fresh-token")])
        let http = harness.stubHTTP([.status(409, "{}"), .status(409, "{}")])

        do {
            _ = try await client.deleteAccount(accountName: "alice")
            XCTFail("expected a failure")
        } catch {
            assertDeletionFailed(error)
        }
        XCTAssertEqual(http.requests.count, 2)
    }

    func testConflictThenUnauthorizedThrows() async {
        harness.stubCeremonies([.success("fresh-token")])
        let http = harness.stubHTTP([.status(409, "{}"), .status(401, "{}")])

        do {
            _ = try await client.deleteAccount(accountName: "alice")
            XCTFail("expected a failure")
        } catch {
            assertDeletionFailed(error)
        }
        XCTAssertEqual(http.requests.count, 2, "one retry in all")
    }

    func testUnauthorizedSignsInAgainAndRetries() async throws {
        harness.stubCeremonies([.success("first-token"), .success("second-token")])
        let http = harness.stubHTTP([.status(401, "{}"), .status(202, Self.receiptBody)])

        let result = try await client.deleteAccount(accountName: "alice")

        guard case .deleted(.some) = result else { return XCTFail("expected a receipt, got \(result)") }
        XCTAssertEqual(harness.ceremonies, ["alice", "alice"])
        XCTAssertEqual(http.requests.map { $0.value(forHTTPHeaderField: "X-Auth-Token") }, ["first-token", "second-token"])
    }

    func testTwoUnauthorizedThrow() async {
        harness.stubCeremonies([.success("first-token"), .success("second-token")])
        let http = harness.stubHTTP([.status(401, "{}"), .status(401, "{}")])

        do {
            _ = try await client.deleteAccount(accountName: "alice")
            XCTFail("expected a failure")
        } catch {
            assertDeletionFailed(error)
        }
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(harness.ceremonies.count, 2)
    }

    func testUnauthorizedThenUserNotFoundIsAlreadyDeleted() async throws {
        harness.stubCeremonies([.success("first-token"), .failure(Self.userNotFound)])
        let http = harness.stubHTTP([.status(401, "{}")])

        let result = try await client.deleteAccount(accountName: "alice")

        XCTAssertEqual(result, .alreadyDeleted)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testUserNotFoundOnTheFirstSignInSendsNothing() async throws {
        harness.stubCeremonies([.failure(Self.userNotFound)])
        let http = harness.stubHTTP([])

        let result = try await client.deleteAccount(accountName: "alice")

        XCTAssertEqual(result, .alreadyDeleted)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testCancelledSignInRethrowsAndSendsNothing() async {
        harness.stubCeremonies([.failure(ASAuthorizationError(.canceled))])
        let http = harness.stubHTTP([])

        do {
            _ = try await client.deleteAccount(accountName: "alice")
            XCTFail("expected the cancellation")
        } catch let error as ASAuthorizationError {
            XCTAssertEqual(error.code, .canceled)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testOtherSignInFailuresAreRethrownUnchanged() async {
        harness.stubCeremonies([.failure(ArkavoError.authenticationFailed("Invalid response from server"))])
        let http = harness.stubHTTP([])

        do {
            _ = try await client.deleteAccount(accountName: "alice")
            XCTFail("expected the ceremony's error")
        } catch let ArkavoError.authenticationFailed(message) {
            XCTAssertEqual(message, "Invalid response from server")
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testServerErrorThrows() async {
        harness.stubCeremonies([.success("fresh-token")])
        let http = harness.stubHTTP([.status(500, #"{"error":"server_error"}"#)])

        do {
            _ = try await client.deleteAccount(accountName: "alice")
            XCTFail("expected a failure")
        } catch {
            assertDeletionFailed(error)
        }
        XCTAssertEqual(http.requests.count, 1, "a 500 is not retried")
    }

    func testTransportErrorThrows() async {
        harness.stubCeremonies([.success("fresh-token")])
        harness.stubHTTP([.failure(URLError(.notConnectedToInternet))])

        do {
            _ = try await client.deleteAccount(accountName: "alice")
            XCTFail("expected a failure")
        } catch {
            assertDeletionFailed(error)
        }
    }

    // MARK: - Refusals

    func testEmptyNameIsRefusedWithoutASignIn() async {
        harness.stubCeremonies([.success("fresh-token")])
        let http = harness.stubHTTP([])

        for name in ["", "   "] {
            do {
                _ = try await client.deleteAccount(accountName: name)
                XCTFail("expected a refusal for \(name.debugDescription)")
            } catch ArkavoError.invalidURL {
                // expected
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertTrue(harness.ceremonies.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testPaddedNameIsRefusedWithoutASignIn() async {
        harness.stubCeremonies([.failure(Self.userNotFound)])
        let http = harness.stubHTTP([])
        harness.store.handle = "alice"

        do {
            _ = try await client.deleteAccount(accountName: " alice")
            XCTFail("expected a refusal")
        } catch ArkavoError.invalidURL {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(harness.ceremonies.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertTrue(harness.store.removals.isEmpty)
        XCTAssertFalse(client.isDeletingAccount)
    }

    func testRefusedWhileConnectingOrAuthenticating() async {
        harness.stubCeremonies([.success("fresh-token")])
        let http = harness.stubHTTP([])

        for state in [ArkavoClientState.connecting, .authenticating] {
            client.currentState = state
            await assertRefused { _ = try await self.client.deleteAccount(accountName: "alice") }
        }
        XCTAssertTrue(harness.ceremonies.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAllowedFromTheErrorState() async throws {
        client.currentState = .error(URLError(.networkConnectionLost))
        harness.stubCeremonies([.success("fresh-token")])
        harness.stubHTTP([.status(202, Self.receiptBody)])

        let result = try await client.deleteAccount(accountName: "alice")

        guard case .deleted = result else { return XCTFail("expected .deleted, got \(result)") }
    }

    func testWhileDeletingEverythingElseIsRefused() async throws {
        let gate = Gate()
        defer { gate.open() } // a failing assertion must not leave the ceremony suspended
        client.authenticator = { _ in
            await gate.pass()
            return "fresh-token"
        }
        let http = harness.stubHTTP([.status(202, Self.receiptBody)])

        let first = Task { try await self.client.deleteAccount(accountName: "alice") }
        await gate.waitUntilHolding()
        XCTAssertTrue(client.isDeletingAccount)

        await assertRefused { _ = try await self.client.deleteAccount(accountName: "alice") }
        await assertRefused { try await self.client.connect(accountName: "alice") }
        await assertRefused { _ = try await self.client.registerUser(handle: "alice", did: "did:key:z1") }
        await assertRefused { try await self.client.linkAppleIdentity(idToken: "t", authorizationCode: "c") }

        gate.open()
        let result = try await first.value
        guard case .deleted = result else { return XCTFail("expected .deleted, got \(result)") }
        XCTAssertEqual(http.requests.count, 1, "the refused calls sent nothing")
        XCTAssertFalse(client.isDeletingAccount)
    }

    func testDeletingFlagClearsAfterAFailure() async {
        harness.stubCeremonies([.failure(ASAuthorizationError(.canceled))])
        harness.stubHTTP([])

        do {
            _ = try await client.deleteAccount(accountName: "alice")
            XCTFail("expected the cancellation")
        } catch let error as ASAuthorizationError {
            XCTAssertEqual(error.code, .canceled)
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertFalse(client.isDeletingAccount)
    }
}
