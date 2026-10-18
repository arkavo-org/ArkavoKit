import AuthenticationServices
import CryptoKit
import XCTest
@testable import ArkavoSocial

/// What `deleteAccount(accountName:)` removes from this device, and when.
///
/// A deletion runs only when the stored handle is the named one and the stored
/// token carries that account's id; otherwise it is refused before any sign-in
/// and removes nothing.
@MainActor
final class ArkavoClientDeletionWipeTests: XCTestCase {
    private static let accepted = ScriptedHTTP.Outcome.status(202, "{}")
    private static let everything = ["token", "sharedHandleAndDID", "identityPair", "didKey", "appleAccount"]
    private static let userNotFound = ArkavoError.authenticationFailed("User Not Found")
    /// A token of the stored account (the harness's "alice").
    private static let aliceToken = DeletionHarness.token(of: DeletionHarness.account)
    private static let otherToken = DeletionHarness.token(of: DeletionHarness.otherAccount)

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

    private struct TimedOut: Error {}

    /// The error `task` threw, or nil when it returned. A waiter still parked
    /// after two seconds is released and `TimedOut` comes back, so the test
    /// fails instead of hanging.
    private func thrownError<T: Sendable>(by task: Task<T, Error>) async -> Error? {
        let client = harness.client
        return await withTaskGroup(of: Error?.self) { group in
            group.addTask {
                do {
                    _ = try await task.value
                    return nil
                } catch {
                    return error
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return nil // cancelled: the waiter finished first
                }
                await releaseParkedWaiters(on: client)
                return TimedOut()
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
        harness.store.token = Self.aliceToken
        harness.store.handle = "alice"

        _ = try await deleteAlice(signIn: .success(Self.aliceToken))

        XCTAssertEqual(harness.store.removals, Self.everything)
        XCTAssertNil(harness.store.token)
        XCTAssertNil(harness.store.handle)
    }

    /// The fresh token's subject is unreadable; the stored handle is "alice".
    func testUnreadableSubjectFallsBackToTheHandle() async throws {
        harness.store.token = Self.aliceToken
        harness.store.handle = "alice"

        _ = try await deleteAlice(signIn: .success("opaque-fresh-token"))

        XCTAssertEqual(harness.store.removals, Self.everything)
    }

    func testDIDKeyFailureDoesNotFailTheDeletion() async throws {
        harness.store.token = Self.aliceToken
        harness.store.handle = "alice"
        harness.store.didKeyDeletionError = KeychainManager.KeychainError.unknown(-25_244)

        let result = try await deleteAlice(signIn: .success(Self.aliceToken))

        XCTAssertEqual(result, .deleted(nil))
        XCTAssertEqual(harness.store.removals, Self.everything, "the steps after the DID key still run")
    }

    // MARK: - Session teardown

    func testSessionIsTornDownFromAnyState() async throws {
        for state in [ArkavoClientState.connected, .disconnected, .error(URLError(.networkConnectionLost))] {
            harness = DeletionHarness()
            installLiveSession(state: state)
            let waiters = await installPendingWaiters()

            _ = try await deleteAlice(signIn: .success(Self.aliceToken))

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
        harness.store.token = Self.aliceToken
        harness.store.handle = "alice"

        let result = try await deleteAlice(signIn: .failure(Self.userNotFound), http: [])

        XCTAssertEqual(result, .alreadyDeleted)
        XCTAssertEqual(harness.store.removals, Self.everything)
    }

    // MARK: - Not this account: refused, nothing removed

    // A deletion of "alice" is scoped to the stored account, so one this device
    // cannot tie to her is refused before any sign-in, and one whose sign-in
    // proves another account is refused before any DELETE. Another account's
    // items are kept because nothing is removed at all.

    func testSharedHandleOfAnotherAccountIsKept() async {
        harness.store.token = Self.aliceToken
        harness.store.handle = "bob"

        await assertRefusedAndRemovesNothing()

        XCTAssertEqual(harness.store.handle, "bob")
        XCTAssertEqual(harness.store.token, Self.aliceToken)
    }

    func testHandleOfDifferentCaseIsAnotherAccount() async {
        harness.store.token = Self.aliceToken
        harness.store.handle = "Alice"

        await assertRefusedAndRemovesNothing()

        XCTAssertEqual(harness.store.handle, "Alice")
    }

    /// No stored handle: nothing says the stored token is alice's.
    func testNoStoredHandleIsNotThisAccount() async {
        harness.store.token = Self.aliceToken
        harness.store.handle = nil

        await assertRefusedAndRemovesNothing()
    }

    /// No stored token: no account id to scope the sign-in to.
    func testNoStoredTokenRemovesNothing() async {
        harness.store.token = nil
        harness.store.handle = "alice"

        await assertRefusedAndRemovesNothing()
    }

    func testUnreadableStoredSubjectRemovesNothing() async {
        harness.store.token = "opaque-stored-token"
        harness.store.handle = "alice"

        await assertRefusedAndRemovesNothing()

        XCTAssertEqual(harness.store.token, "opaque-stored-token")
    }

    func testUnreadableSubjectWithAnotherHandleKeepsTheToken() async {
        harness.store.token = "opaque-stored-token"
        harness.store.handle = "bob"

        await assertRefusedAndRemovesNothing()

        XCTAssertEqual(harness.store.token, "opaque-stored-token")
    }

    /// Bob is signed in here: alice's deletion is refused before any sign-in,
    /// and bob's session and items are left alone.
    func testAnotherSignedInAccountIsLeftAlone() async {
        harness.store.token = Self.otherToken
        harness.store.handle = "bob"

        await assertRefusedAndRemovesNothing()

        XCTAssertEqual(harness.store.token, Self.otherToken)
        XCTAssertEqual(harness.store.handle, "bob")
    }

    /// Another Arkavo app saved bob's token beside alice's handle. The sign-in
    /// scoped to that token proves bob, so the deletion is refused before any
    /// DELETE: bob is not deleted, his passkeys stay, and alice's items stay.
    func testStoredTokenOfAnotherAccountIsKept() async {
        harness.store.token = Self.otherToken
        harness.store.handle = "alice"
        installLiveSession()
        harness.stubReplies([.success(AuthenticationReply(token: Self.otherToken, handle: "bob"))])
        let http = harness.stubHTTP([Self.accepted])

        do {
            let result = try await harness.client.deleteAccount(accountName: "alice")
            XCTFail("expected notConnected, got \(result)")
        } catch ArkavoError.notConnected {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertEqual(harness.ceremonies, [DeletionHarness.otherAccount])
        XCTAssertTrue(http.requests.isEmpty, "no DELETE is sent")
        XCTAssertTrue(harness.store.removals.isEmpty)
        XCTAssertEqual(harness.store.token, Self.otherToken)
        XCTAssertEqual(harness.store.handle, "alice")
        XCTAssertTrue(harness.reporter.noAcceptedCredentials.isEmpty, "bob's passkeys stay")
        assertSessionUntouched()
    }

    // MARK: - Nothing removed on failure

    func testTwoConflictsRemoveNothing() async {
        harness.store.token = Self.aliceToken
        harness.store.handle = "alice"
        installLiveSession()

        await assertThrewAccountDeletionFailed {
            try await self.deleteAlice(signIn: .success(Self.aliceToken), http: [.status(409, "{}"), .status(409, "{}")])
        }

        XCTAssertTrue(harness.store.removals.isEmpty)
        assertSessionUntouched()
    }

    func testCancelledSignInRemovesNothing() async {
        harness.store.token = Self.aliceToken
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
        harness.store.token = Self.aliceToken
        harness.store.handle = "alice"
        installLiveSession()

        await assertThrewAccountDeletionFailed {
            try await self.deleteAlice(signIn: .success(Self.aliceToken), http: [.failure(URLError(.timedOut))])
        }

        XCTAssertTrue(harness.store.removals.isEmpty)
        assertSessionUntouched()
    }

    func testServerErrorRemovesNothing() async {
        harness.store.token = Self.aliceToken
        harness.store.handle = "alice"
        installLiveSession()

        await assertThrewAccountDeletionFailed {
            try await self.deleteAlice(signIn: .success(Self.aliceToken), http: [.status(500, "{}")])
        }

        XCTAssertTrue(harness.store.removals.isEmpty)
        assertSessionUntouched()
    }

    func testPaddedNameIsRefusedAndRemovesNothing() async {
        harness.store.token = Self.aliceToken
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

        _ = try await deleteAlice(signIn: .success(Self.aliceToken))
        delegate.reset() // the teardown's own .disconnected is expected; only later events matter

        let cancelled = URLError(.cancelled)
        harness.client.handleSocketState(.error(cancelled), from: staleSocket)
        await harness.client.handleReceiveResult(.failure(cancelled), from: staleSocket)
        harness.client.handleInitialPingResult(cancelled, from: staleSocket)
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

    func testPingFailureOfAReplacedSocketIsIgnoredButTheCurrentOneStillCounts() async throws {
        installLiveSession()
        let staleSocket = try XCTUnwrap(harness.client.webSocket)
        let currentSocket = harness.client.session!.webSocketTask(with: URL(string: "wss://kas.example.test/2")!)
        harness.client.webSocket = currentSocket
        harness.client.currentState = .connecting
        let waiters = await installPendingWaiters()

        harness.client.handleInitialPingResult(URLError(.cancelled), from: staleSocket)
        XCTAssertEqual(harness.client.currentState, .connecting)
        XCTAssertNotNil(harness.client.connectionContinuation, "the closed socket's ping does not fail the pending connection")

        // Control: the current socket's ping failure still fails the connection.
        harness.client.handleInitialPingResult(URLError(.timedOut), from: currentSocket)
        XCTAssertEqual(harness.client.currentState, .error(URLError(.timedOut)))
        let connectionError = await thrownError(by: waiters.connection)
        XCTAssertEqual((connectionError as? URLError)?.code, .timedOut)

        // A ping failure leaves message handlers alone; release this one so its task finishes.
        releaseParkedWaiters(on: harness.client)
        _ = await thrownError(by: waiters.handler)
    }

    // MARK: - disconnect()

    /// The closed socket's late callbacks are dropped, so `disconnect()` itself
    /// must fail whatever waits on the connection (a `decryptNanoTDF` waiting
    /// for its key, say).
    func testDisconnectFailsPendingWaiters() async throws {
        installLiveSession()
        let staleSocket = try XCTUnwrap(harness.client.webSocket)
        let waiters = await installPendingWaiters()

        await harness.client.disconnect()
        let cancelled = URLError(.cancelled)
        harness.client.handleSocketState(.error(cancelled), from: staleSocket)
        await harness.client.handleReceiveResult(.failure(cancelled), from: staleSocket)
        harness.client.handleInitialPingResult(cancelled, from: staleSocket)

        XCTAssertTrue(harness.client.messageHandlers.isEmpty)
        XCTAssertNil(harness.client.connectionContinuation)
        XCTAssertEqual(harness.client.currentState, .disconnected, "the closed socket's late error does not replace .disconnected")
        let handlerError = await thrownError(by: waiters.handler)
        let connectionError = await thrownError(by: waiters.connection)
        assertConnectionClosed(handlerError)
        assertConnectionClosed(connectionError)
    }

    func testTearDownInvalidatesTheSession() async throws {
        let probe = InvalidationProbe()
        let client = harness.client
        client.currentState = .connected
        let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
        client.session = session
        client.webSocket = session.webSocketTask(with: URL(string: "wss://kas.example.test")!)

        _ = try await deleteAlice(signIn: .success(Self.aliceToken))

        await fulfillment(of: [probe.invalidated], timeout: 5)
        XCTAssertNil(client.session)
    }

    /// Deletes "alice" with a live session installed and expects the refusal:
    /// `.notConnected`, no sign-in, no request, nothing removed, session untouched.
    private func assertRefusedAndRemovesNothing(file: StaticString = #filePath, line: UInt = #line) async {
        installLiveSession()
        harness.stubCeremonies([.success(Self.aliceToken)])
        let http = harness.stubHTTP([Self.accepted])

        do {
            let result = try await harness.client.deleteAccount(accountName: "alice")
            XCTFail("expected notConnected, got \(result)", file: file, line: line)
        } catch ArkavoError.notConnected {
            // expected
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }

        XCTAssertTrue(harness.ceremonies.isEmpty, "no sign-in", file: file, line: line)
        XCTAssertTrue(http.requests.isEmpty, "no request", file: file, line: line)
        XCTAssertTrue(harness.store.removals.isEmpty, file: file, line: line)
        XCTAssertTrue(harness.reporter.noAcceptedCredentials.isEmpty, "no passkey is cleared", file: file, line: line)
        assertSessionUntouched(file: file, line: line)
    }

    private func assertSessionUntouched(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(harness.client.currentState, .connected, "a failed deletion leaves the session alone", file: file, line: line)
        XCTAssertNotNil(harness.client.sessionSymmetricKey, file: file, line: line)
        XCTAssertNotNil(harness.client.webSocket, file: file, line: line)
        XCTAssertNotNil(harness.client.session, file: file, line: line)
    }
}

/// Resumes whatever is still parked on `client`, so a failing test leaks no
/// continuation.
@MainActor
private func releaseParkedWaiters(on client: ArkavoClient) {
    let handlers = client.messageHandlers.values
    client.messageHandlers.removeAll()
    let connection = client.connectionContinuation
    client.connectionContinuation = nil
    for handler in handlers {
        handler.resume(throwing: CancellationError())
    }
    connection?.resume(throwing: CancellationError())
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
