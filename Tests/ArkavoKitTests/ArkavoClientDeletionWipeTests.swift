import AuthenticationServices
import CryptoKit
import XCTest
@testable import ArkavoSocial

/// What `deleteAccount(accountName:)` removes from this device, and when.
@MainActor
final class ArkavoClientDeletionWipeTests: XCTestCase {
    private static let accepted = ScriptedHTTP.Outcome.status(202, "{}")
    private static let everything = ["token", "sharedHandleAndDID", "identityPair", "didKey", "appleAccount"]
    private static let userNotFound = ArkavoError.authenticationFailed("User Not Found")

    private var harness: DeletionHarness!

    override func setUp() async throws {
        harness = DeletionHarness()
    }

    private func deleteAlice(signIn: Result<String, Error>, http: [ScriptedHTTP.Outcome] = [accepted]) async throws -> AccountDeletionResult {
        harness.stubCeremonies([signIn])
        harness.stubHTTP(http)
        return try await harness.client.deleteAccount(accountName: "alice")
    }

    /// A live-looking session: connected, with a key and a socket.
    private func installLiveSession(state: ArkavoClientState = .connected) {
        let client = harness.client
        client.currentState = state
        client.sessionSymmetricKey = SymmetricKey(size: .bits256)
        let session = URLSession(configuration: .ephemeral)
        client.session = session
        client.webSocket = session.webSocketTask(with: URL(string: "wss://kas.example.test")!)
    }

    /// Parks a message handler and a connection continuation on the client, each
    /// watched by a task that reports how it was resumed.
    private func installPendingWaiters() async -> (handler: Task<Data, Error>, connection: Task<Void, Error>) {
        let client = harness.client
        let handler = Task { @MainActor in
            try await withCheckedThrowingContinuation { client.messageHandlers[7] = $0 }
        }
        let connection = Task { @MainActor in
            try await withCheckedThrowingContinuation { client.connectionContinuation = $0 }
        }
        while client.messageHandlers.isEmpty || client.connectionContinuation == nil {
            await Task.yield()
        }
        return (handler, connection)
    }

    private func assertThrewAccountDeletionFailed(_ call: () async throws -> AccountDeletionResult, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let result = try await call()
            XCTFail("expected the deletion to throw, got \(result)", file: file, line: line)
        } catch let ArkavoError.authenticationFailed(message) {
            XCTAssertEqual(message, "Account deletion failed", file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }

    private func assertConnectionClosed(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        guard case ArkavoError.connectionFailed? = error else {
            return XCTFail("expected connectionFailed, got \(String(describing: error))", file: file, line: line)
        }
    }

    // MARK: - After .deleted

    func testSameAccountRemovesEverything() async throws {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = "alice"

        _ = try await deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")))

        XCTAssertEqual(harness.store.removals, Self.everything)
        XCTAssertNil(harness.store.token)
        XCTAssertNil(harness.store.handle)
    }

    func testStoredTokenOfAnotherAccountIsKept() async throws {
        harness.store.token = TestCWT.token(sub: "user-2")
        harness.store.handle = "alice"

        _ = try await deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")))

        XCTAssertEqual(harness.store.removals, ["sharedHandleAndDID", "identityPair", "didKey", "appleAccount"])
        XCTAssertEqual(harness.store.token, TestCWT.token(sub: "user-2"))
    }

    func testSharedHandleOfAnotherAccountIsKept() async throws {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = "bob"

        _ = try await deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")))

        XCTAssertEqual(harness.store.removals, ["token", "appleAccount"])
        XCTAssertEqual(harness.store.handle, "bob")
    }

    func testHandleOfDifferentCaseIsAnotherAccount() async throws {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = "Alice"

        _ = try await deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")))

        XCTAssertEqual(harness.store.removals, ["token", "appleAccount"])
        XCTAssertEqual(harness.store.handle, "Alice")
    }

    func testNoStoredHandleCountsAsThisAccount() async throws {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = nil

        _ = try await deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")))

        XCTAssertEqual(harness.store.removals, Self.everything)
    }

    func testNoStoredTokenRemovesNoToken() async throws {
        harness.store.token = nil
        harness.store.handle = "alice"

        _ = try await deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")))

        XCTAssertEqual(harness.store.removals, ["sharedHandleAndDID", "identityPair", "didKey", "appleAccount"])
    }

    func testUnreadableSubjectFallsBackToTheHandle() async throws {
        harness.store.token = "opaque-stored-token"
        harness.store.handle = "alice"

        _ = try await deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")))

        XCTAssertEqual(harness.store.removals, Self.everything)
    }

    func testUnreadableSubjectWithAnotherHandleKeepsTheToken() async throws {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = "bob"

        _ = try await deleteAlice(signIn: .success("opaque-fresh-token"))

        XCTAssertEqual(harness.store.removals, ["appleAccount"])
        XCTAssertNotNil(harness.store.token)
    }

    func testDIDKeyFailureDoesNotFailTheDeletion() async throws {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = "alice"
        harness.store.didKeyDeletionError = KeychainManager.KeychainError.unknown(-25_244)

        let result = try await deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")))

        XCTAssertEqual(result, .deleted(nil))
        XCTAssertEqual(harness.store.removals, Self.everything, "the steps after the DID key still run")
    }

    // MARK: - Session teardown

    func testSessionIsTornDownFromAnyState() async throws {
        for state in [ArkavoClientState.connected, .disconnected, .error(URLError(.networkConnectionLost))] {
            harness = DeletionHarness()
            installLiveSession(state: state)
            let waiters = await installPendingWaiters()

            _ = try await deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")))

            let client = harness.client
            XCTAssertNil(client.sessionSymmetricKey, "from \(state)")
            XCTAssertNil(client.getSessionSymmetricKey(), "from \(state)")
            XCTAssertNil(client.webSocket, "from \(state)")
            XCTAssertNil(client.session, "from \(state)")
            XCTAssertEqual(client.currentState, .disconnected, "from \(state)")
            XCTAssertTrue(client.messageHandlers.isEmpty, "from \(state)")
            XCTAssertNil(client.connectionContinuation, "from \(state)")

            do {
                _ = try await waiters.handler.value
                XCTFail("the pending message handler was not failed, from \(state)")
            } catch {
                assertConnectionClosed(error)
            }
            do {
                try await waiters.connection.value
                XCTFail("the pending connection was not failed, from \(state)")
            } catch {
                assertConnectionClosed(error)
            }
        }
    }

    func testSessionIsTornDownAfterAlreadyDeletedToo() async throws {
        installLiveSession()
        harness.store.handle = "alice"

        let result = try await deleteAlice(signIn: .failure(Self.userNotFound), http: [])

        XCTAssertEqual(result, .alreadyDeleted)
        XCTAssertNil(harness.client.sessionSymmetricKey)
        XCTAssertNil(harness.client.webSocket)
        XCTAssertNil(harness.client.session)
        XCTAssertEqual(harness.client.currentState, .disconnected)
    }

    // MARK: - After .alreadyDeleted

    func testAlreadyDeletedWithThisHandleRemovesEverything() async throws {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = "alice"

        let result = try await deleteAlice(signIn: .failure(Self.userNotFound), http: [])

        XCTAssertEqual(result, .alreadyDeleted)
        XCTAssertEqual(harness.store.removals, Self.everything)
    }

    func testAlreadyDeletedWithAnotherHandleKeepsTheSharedItems() async throws {
        harness.store.token = TestCWT.token(sub: "user-2")
        harness.store.handle = "bob"
        installLiveSession()

        let result = try await deleteAlice(signIn: .failure(Self.userNotFound), http: [])

        XCTAssertEqual(result, .alreadyDeleted)
        XCTAssertEqual(harness.store.removals, ["appleAccount"])
        XCTAssertEqual(harness.client.currentState, .disconnected)
    }

    // MARK: - Nothing removed on failure

    func testTwoConflictsRemoveNothing() async {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = "alice"
        installLiveSession()

        await assertThrewAccountDeletionFailed {
            try await self.deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")), http: [.status(409, "{}"), .status(409, "{}")])
        }

        XCTAssertTrue(harness.store.removals.isEmpty)
        assertSessionUntouched()
    }

    func testCancelledSignInRemovesNothing() async {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = "alice"
        installLiveSession()

        do {
            _ = try await deleteAlice(signIn: .failure(ASAuthorizationError(.canceled)), http: [])
            XCTFail("expected the cancellation")
        } catch let error as ASAuthorizationError {
            XCTAssertEqual(error.code, .canceled)
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertTrue(harness.store.removals.isEmpty)
        assertSessionUntouched()
    }

    func testTransportErrorRemovesNothing() async {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = "alice"
        installLiveSession()

        await assertThrewAccountDeletionFailed {
            try await self.deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")), http: [.failure(URLError(.timedOut))])
        }

        XCTAssertTrue(harness.store.removals.isEmpty)
        assertSessionUntouched()
    }

    func testServerErrorRemovesNothing() async {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = "alice"
        installLiveSession()

        await assertThrewAccountDeletionFailed {
            try await self.deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")), http: [.status(500, "{}")])
        }

        XCTAssertTrue(harness.store.removals.isEmpty)
        assertSessionUntouched()
    }

    func testPaddedNameIsRefusedAndRemovesNothing() async {
        harness.store.token = TestCWT.token(sub: "user-1")
        harness.store.handle = "alice"
        installLiveSession()
        harness.stubCeremonies([.failure(Self.userNotFound)])
        let http = harness.stubHTTP([])

        for name in [" alice", "alice ", "alice\n"] {
            do {
                _ = try await harness.client.deleteAccount(accountName: name)
                XCTFail("expected a refusal for \(name.debugDescription)")
            } catch ArkavoError.invalidURL {
                // expected
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }

        XCTAssertTrue(harness.ceremonies.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertTrue(harness.store.removals.isEmpty)
        assertSessionUntouched()
    }

    // MARK: - Late callbacks of the torn-down socket

    func testLateCancellationOfTheClosedSocketDoesNotOverwriteDisconnected() async throws {
        installLiveSession()
        let staleSocket = try XCTUnwrap(harness.client.webSocket)
        let delegate = RecordingClientDelegate()
        harness.client.delegate = delegate

        _ = try await deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")))
        delegate.reset() // the teardown's own .disconnected is expected; only later events matter

        let cancelled = URLError(.cancelled)
        harness.client.handleSocketState(.error(cancelled), from: staleSocket)
        await harness.client.handleReceiveResult(.failure(cancelled), from: staleSocket)
        harness.client.handleSocketState(.disconnected, from: staleSocket)

        XCTAssertEqual(harness.client.currentState, .disconnected)
        XCTAssertTrue(delegate.errors.isEmpty, "the delegate hears nothing from the closed socket")
        XCTAssertTrue(delegate.states.isEmpty, "no state change from the closed socket")
    }

    func testCallbacksOfAReplacedSocketAreIgnoredButTheCurrentOneStillCounts() async throws {
        installLiveSession()
        let staleSocket = try XCTUnwrap(harness.client.webSocket)
        let currentSocket = harness.client.session!.webSocketTask(with: URL(string: "wss://kas.example.test/2")!)
        harness.client.webSocket = currentSocket
        harness.client.currentState = .connecting
        let delegate = RecordingClientDelegate()
        harness.client.delegate = delegate

        harness.client.handleSocketState(.error(URLError(.cancelled)), from: staleSocket)
        await harness.client.handleReceiveResult(.failure(URLError(.cancelled)), from: staleSocket)
        XCTAssertEqual(harness.client.currentState, .connecting)
        XCTAssertTrue(delegate.errors.isEmpty)

        // Control: the current socket's callbacks still update state.
        harness.client.handleSocketState(.connected, from: currentSocket)
        XCTAssertEqual(harness.client.currentState, .connected)

        await harness.client.handleReceiveResult(.failure(URLError(.networkConnectionLost)), from: currentSocket)
        if case .error = harness.client.currentState {} else {
            XCTFail("the current socket's receive failure must set .error, got \(harness.client.currentState)")
        }
        XCTAssertEqual(delegate.errors.count, 1, "the current socket's receive failure reaches the delegate")
    }

    func testStaleSocketDoesNotFailPendingWaiters() async throws {
        installLiveSession()
        let staleSocket = try XCTUnwrap(harness.client.webSocket)
        harness.client.webSocket = harness.client.session!.webSocketTask(with: URL(string: "wss://kas.example.test/2")!)
        let waiters = await installPendingWaiters()

        harness.client.handleSocketState(.error(URLError(.cancelled)), from: staleSocket)
        await harness.client.handleReceiveResult(.failure(URLError(.cancelled)), from: staleSocket)

        XCTAssertFalse(harness.client.messageHandlers.isEmpty)
        XCTAssertNotNil(harness.client.connectionContinuation)

        // Resolve the waiters so the tasks finish.
        harness.client.handleSocketState(.error(URLError(.networkConnectionLost)), from: harness.client.webSocket!)
        _ = try? await waiters.handler.value
        _ = try? await waiters.connection.value
    }

    func testTearDownInvalidatesTheSession() async throws {
        let probe = InvalidationProbe()
        let client = harness.client
        client.currentState = .connected
        let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
        client.session = session
        client.webSocket = session.webSocketTask(with: URL(string: "wss://kas.example.test")!)

        _ = try await deleteAlice(signIn: .success(TestCWT.token(sub: "user-1")))

        await fulfillment(of: [probe.invalidated], timeout: 5)
        XCTAssertNil(client.session)
    }

    private func assertSessionUntouched(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(harness.client.currentState, .connected, "a failed deletion leaves the session alone", file: file, line: line)
        XCTAssertNotNil(harness.client.sessionSymmetricKey, file: file, line: line)
        XCTAssertNotNil(harness.client.webSocket, file: file, line: line)
        XCTAssertNotNil(harness.client.session, file: file, line: line)
    }
}

/// Records what the client tells its delegate.
@MainActor
private final class RecordingClientDelegate: ArkavoClientDelegate {
    private(set) var states: [ArkavoClientState] = []
    private(set) var errors: [Error] = []

    func reset() {
        states = []
        errors = []
    }

    func clientDidChangeState(_: ArkavoClient, state: ArkavoClientState) { states.append(state) }
    func clientDidReceiveMessage(_: ArkavoClient, message _: Data) {}
    func clientDidReceiveError(_: ArkavoClient, error: Error) { errors.append(error) }
}

/// Fulfils `invalidated` when its URLSession is invalidated.
private final class InvalidationProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    let invalidated = XCTestExpectation(description: "session invalidated")

    func urlSession(_: URLSession, didBecomeInvalidWithError _: Error?) {
        invalidated.fulfill()
    }
}
