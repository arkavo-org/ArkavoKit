import AuthenticationServices
import CryptoKit
import Foundation
import OpenTDFKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Main errors that can occur in ArkavoClient operations
public enum ArkavoError: Error {
    case invalidURL
    case authenticationFailed(String)
    case connectionFailed(String)
    case invalidResponse
    case messageError(String)
    case notConnected
    case invalidState
    case profileNotFound(String)
    /// identity does not know the passkey the person picked: its account is gone.
    /// The passkey is reported to the system first, so the sheet stops offering it.
    /// The report is best effort: it needs iOS / macOS 26.2, and a failed report is
    /// only logged.
    case unknownPasskey
}

/// Represents the current state of the ArkavoClient
public enum ArkavoClientState: Equatable, Sendable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case error(Error)

    public static func == (lhs: ArkavoClientState, rhs: ArkavoClientState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.authenticating, .authenticating),
             (.connected, .connected):
            true
        case let (.error(lhsError), .error(rhsError)):
            lhsError.localizedDescription == rhsError.localizedDescription
        default:
            false
        }
    }
}

/// Protocol for handling ArkavoClient events
@MainActor
public protocol ArkavoClientDelegate: AnyObject {
    func clientDidChangeState(_ client: ArkavoClient, state: ArkavoClientState)
    func clientDidReceiveMessage(_ client: ArkavoClient, message: Data)
    func clientDidReceiveError(_ client: ArkavoClient, error: Error)
}

/// Main ArkavoClient class handling WebAuthn authentication and WebSocket communication
@MainActor
public final class ArkavoClient: NSObject {
    private let authURL: URL // for WebAuthn
    private let websocketURL: URL // for WebSocket
    private let relyingPartyID: String
    private let curve: KeyExchangeCurve
    private var keyPair: CurveKeyPair?
    private var sharedSecret: SharedSecret?
    private var salt: Data?
    private var kasPublicKey: P256.KeyAgreement.PublicKey?
    // Internal rather than private so tests can install and observe a live-looking session.
    var sessionSymmetricKey: SymmetricKey?
    var webSocket: URLSessionWebSocketTask?
    var session: URLSession?
    private let delegateQueue = OperationQueue()
    private let socketDelegate: WebSocketDelegate
    var connectionContinuation: CheckedContinuation<Void, Error>?
    var messageHandlers: [UInt8: CheckedContinuation<Data, Error>] = [:]
    private let profileCache = ProfileCache(capacity: 100)

    // MARK: - Test seams (internal; tests replace them through @testable import)

    /// The passkey ceremony that re-authenticates an account for its deletion:
    /// account id → identity's reply (a fresh auth CWT and the account's
    /// handle). Never stores the token.
    lazy var authenticator: @MainActor (UUID) async throws -> AuthenticationReply = { [unowned self] account in
        try await self.passkeyCeremony(account: account)
    }

    /// Performs an identity REST request. Used by the passkey ceremony (both
    /// `/authenticate` requests) and the account-deletion and Apple-link requests.
    var httpData: @MainActor (URLRequest) async throws -> (Data, URLResponse) = ArkavoClient.http3Data(for:)

    /// The keychain items account deletion and Apple linking touch.
    var credentialStore: any AccountCredentialStore = KeychainCredentialStore()

    /// The system passkey sheet: an assertion request → the picked passkey's assertion.
    /// A cancelled sheet throws `ASAuthorizationError` (`.canceled`) unchanged.
    lazy var assertionProvider: @MainActor (ASAuthorizationPlatformPublicKeyCredentialAssertionRequest) async throws -> PasskeyAssertion = { [unowned self] request in
        let assertion = try await self.performAuthentication(request: request)
        return PasskeyAssertion(
            credentialID: assertion.credentialID,
            rawClientDataJSON: assertion.rawClientDataJSON,
            rawAuthenticatorData: assertion.rawAuthenticatorData,
            signature: assertion.signature,
            userID: assertion.userID
        )
    }

    /// Tells the system which passkeys identity no longer accepts.
    var credentialReporter: any PasskeyCredentialReporting = SystemPasskeyCredentialReporter()

    /// Performs a request that opts into HTTP/3 on the first hop.
    ///
    /// `URLRequest.assumesHTTP3Capable` lets the first request negotiate HTTP/3
    /// without waiting for an `Alt-Svc` advertisement — `identity.arkavo.net`
    /// advertises `alt-svc: h3=":443"`. URLSession falls back to HTTP/2 when a
    /// server is not h3-capable. Calls share `identitySession`, which keeps
    /// HTTPCookieStorage.shared, so the Apple-link nonce→link session cookie is replayed unchanged.
    ///
    /// Used for every identity REST call site, which spans `identity.arkavo.net`
    /// (WebAuthn/OAuth) and `xrpc.arkavo.net` (profile fetches). The flag is safe
    /// on hosts that do not advertise h3: URLSession simply uses HTTP/2.
    private static func http3Data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.assumesHTTP3Capable = true
        return try await identitySession.data(for: request)
    }

    /// The session for identity and profile calls. It refuses TLS below 1.3: the passkey
    /// token C2PA signing sends comes from here, and the C2PA conformance program's
    /// Level 1 (O.5) asks for TLS 1.3 on that path. It keeps the shared cookie store.
    nonisolated static let identitySession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        configuration.httpCookieStorage = .shared
        return URLSession(configuration: configuration)
    }()

    private static func http3Data(from url: URL) async throws -> (Data, URLResponse) {
        try await http3Data(for: URLRequest(url: url))
    }

    public var currentState: ArkavoClientState = .disconnected {
        didSet {
            delegate?.clientDidChangeState(self, state: currentState)
        }
    }

    public func getSessionSymmetricKey() -> SymmetricKey? {
        sessionSymmetricKey
    }

    public weak var delegate: ArkavoClientDelegate?

    /// True while `deleteAccount(accountName:)` runs. `connect`, `registerUser`
    /// and `linkAppleIdentity` refuse with `ArkavoError.invalidState` meanwhile.
    private(set) var isDeletingAccount = false
    private let presentationProvider: ASAuthorizationControllerPresentationContextProviding
    public var currentToken: String? {
        // TODO: Check if the token has expired
        KeychainManager.getAuthenticationToken()
    }

    public init(authURL: URL,
                websocketURL: URL,
                relyingPartyID: String,
                curve: KeyExchangeCurve = .p256,
                presentationProvider: ASAuthorizationControllerPresentationContextProviding? = nil)
    {
        self.authURL = authURL
        self.websocketURL = websocketURL
        self.relyingPartyID = relyingPartyID
        self.curve = curve
        socketDelegate = WebSocketDelegate()

        #if os(iOS)
            self.presentationProvider = presentationProvider ?? DefaultIOSPresentationProvider()
        #elseif os(macOS)
            self.presentationProvider = presentationProvider ?? DefaultMacPresentationProvider()
        #else
            self.presentationProvider = presentationProvider ?? DefaultPresentationProvider()
        #endif

        super.init()

        socketDelegate.setStateHandler { [weak self] newState, task in
            Task { @MainActor [weak self] in
                self?.handleSocketState(newState, from: task)
            }
        }

        // Start receiving messages when connection is established
        socketDelegate.onConnect = { [weak self] in
            self?.receiveMessage()
        }
    }

    // MARK: - Socket callbacks

    /// Applies a state change reported by the socket delegate. A task that is no
    /// longer `webSocket` (cancelled by `disconnect()`, the connect fallback or
    /// account deletion) is stale: its late cancellation error must not
    /// overwrite the state that replaced it. Internal so tests can drive it.
    func handleSocketState(_ newState: ArkavoClientState, from task: URLSessionTask) {
        guard task === webSocket else { return }
        print("WebSocket state changing to: \(newState)")
        currentState = newState

        // Resume the continuation when connected
        switch newState {
        case .connected:
            if let continuation = connectionContinuation {
                connectionContinuation = nil
                continuation.resume(returning: ())
            }
        case let .error(error):
            if let continuation = connectionContinuation {
                connectionContinuation = nil
                continuation.resume(throwing: error)
            }
            // Also handle any pending message handlers
            for handler in messageHandlers.values {
                handler.resume(throwing: error)
            }
            messageHandlers.removeAll()
        case .disconnected:
            // Clean up any pending handlers on disconnect
            let error = ArkavoError.connectionFailed("Connection disconnected")
            for handler in messageHandlers.values {
                handler.resume(throwing: error)
            }
            messageHandlers.removeAll()
        case .connecting:
            print("connecting")
        case .authenticating:
            print("authenticating")
        }
    }

    // MARK: - Public Methods

    /// Whether the cached session (the stored token and handle) can be reused without a
    /// passkey ceremony. It needs both, so a token alone never "signs in" with an empty
    /// handle; and when an `account` is asked for, the token must be that account's.
    nonisolated static func reusesCachedSession(token: String?, handle: String?, account: UUID?) -> Bool {
        guard let token, !token.isEmpty, let handle, !handle.isEmpty else { return false }
        return isSession(token: token, of: account)
    }

    /// Whether a connected client keeps its live socket. It needs a stored handle to
    /// return; and when an `account` is asked for, the stored token must be that
    /// account's. With no `account` the handle alone decides.
    nonisolated static func keepsConnectedSession(token: String?, handle: String?, account: UUID?) -> Bool {
        guard let handle, !handle.isEmpty else { return false }
        return isSession(token: token, of: account)
    }

    /// true when no account is asked for. Otherwise whether the token's CWT `sub`
    /// (read without a signature check; the server verifies the token) is `account`,
    /// compared as a UUID. A missing or unreadable token is no account's session.
    private nonisolated static func isSession(token: String?, of account: UUID?) -> Bool {
        guard let account else { return true }
        guard let token, let subject = CWTSubject.sub(fromToken: token) else { return false }
        return UUID(uuidString: subject) == account
    }

    /// Signs in with a passkey (no account name) and opens the socket.
    ///
    /// A session already on this device (a live socket, or the stored token and
    /// handle) is reused without a sheet when it fits:
    /// - With no `account`, whichever account it is. With no session, the passkey
    ///   the person picks names the account.
    /// - With an `account`, a cached session of `account` (its token's `sub`) is
    ///   reused without a sheet; one of another account, or one whose token names
    ///   no readable account, is dropped and the scoped ceremony runs: a live
    ///   socket is torn down, the stored token is deleted, and the sheet offers
    ///   only `account`'s passkeys.
    ///
    /// Connected but with no stored handle to return, it likewise tears down the
    /// live socket (pending message handlers fail), deletes the stored token and
    /// shows a passkey sheet. A stored token the server refuses is deleted and the
    /// ceremony runs.
    ///
    /// - Parameter account: the account to sign in; `nil` lets the passkey choose.
    /// - Returns: the signed-in account's handle.
    @discardableResult
    @MainActor
    public func connect(account: UUID? = nil) async throws -> String {
        guard !isDeletingAccount else { throw ArkavoError.invalidState }
        print("ArkavoClient: Connecting...")
        // Check current state more thoroughly
        switch currentState {
        case .disconnected:
            // OK to proceed
            break
        case .error:
            // First disconnect if we're in error state
            await disconnect()
        case .connected:
            let handle = KeychainManager.getArkavoHandle()
            if Self.keepsConnectedSession(token: KeychainManager.getAuthenticationToken(), handle: handle, account: account),
               let handle
            {
                print("Already connected, no need to reconnect")
                return handle
            }
            // Connected, but no handle to return or not `account`'s session: drop
            // it (disconnect() also deletes the stored token) and sign in again.
            print("ArkavoClient: connected session does not fit this sign-in; dropping it")
            await disconnect()
        case .connecting, .authenticating:
            throw ArkavoError.invalidState
        }

        // Fast path: try the cached CWT before running the passkey ceremony.
        // Server is authoritative — if the handshake succeeds, we skip the
        // WebAuthn ceremony entirely. If it fails for any reason (expired,
        // revoked, network), we drop the cached token and fall through to the
        // ceremony branch below. A token without a stored handle is not a session,
        // and neither is another account's when `account` is asked for.
        let cachedToken = KeychainManager.getAuthenticationToken()
        let cachedHandle = KeychainManager.getArkavoHandle()
        if Self.reusesCachedSession(token: cachedToken, handle: cachedHandle, account: account), let cachedHandle {
            do {
                currentState = .connecting
                try await setupWebSocketConnection()
                try await waitForConnection()
                try await sendInitialMessages()
                return cachedHandle
            } catch {
                print("ArkavoClient: cached token rejected (\(error)); falling back to passkey ceremony")
                KeychainManager.deleteAuthenticationToken()
                // Tear down the half-open WebSocket inline so the ceremony branch
                // enters from a clean state. We can't use disconnect() here: its
                // guard requires currentState == .connected, so it's a no-op when
                // the fast-path failed mid-handshake (state is .connecting/.error).
                webSocket?.cancel()
                webSocket = nil
                session = nil
                currentState = .disconnected
            }
        } else if cachedToken != nil {
            print("ArkavoClient: cached token does not fit this sign-in; dropping it")
            KeychainManager.deleteAuthenticationToken()
        }

        do {
            // First authenticate
            currentState = .authenticating
            let reply = try await passkeyCeremony(account: account)
            // The handle first: should the token's write fail, no token is left
            // beside a stale handle, so the next connect runs the ceremony.
            try KeychainManager.saveArkavoHandle(reply.handle)
            try KeychainManager.saveAuthenticationToken(reply.token)

            // Then establish WebSocket connection
            currentState = .connecting
            try await setupWebSocketConnection()
            // Wait for connection to complete
            try await waitForConnection()
            // swap keys
            try await sendInitialMessages()
            return reply.handle
        } catch {
            print("connect error: \(error)")
            if let kcError = error as? KeychainManager.KeychainError {
                switch kcError {
                case .itemNotFound:
                    print("ArkavoClient.connect: Keychain item not found (likely -25300). Will not trigger immediate retry.")
                case let .unknown(status):
                    print("ArkavoClient.connect: Keychain unknown status=\(status)")
                default:
                    break
                }
            }
            currentState = .error(error)
            throw error
        }
    }

    private func waitForConnection() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { [weak self] continuation in
                    guard let self else {
                        continuation.resume(throwing: ArkavoError.connectionFailed("Client deallocated"))
                        return
                    }
                    Task { @MainActor in
                        self.connectionContinuation = continuation
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                throw ArkavoError.connectionFailed("Connection timeout")
            }

            try await group.next()
            group.cancelAll()
        }
    }

    public func disconnect() async {
        guard currentState == .connected else { return }

        currentState = .disconnected
        webSocket?.cancel()
        webSocket = nil
        session = nil
        // The cancelled socket's callbacks are ignored, so nothing else fails these.
        failPendingWaiters(ArkavoError.connectionFailed("Connection disconnected"))
        KeychainManager.deleteAuthenticationToken()
    }

    /// Deletes the user's account from the server
    /// - Throws: ArkavoError if the deletion fails
    @available(*, deprecated, message: "Use deleteAccount(accountName:)")
    public func deleteAccount() async throws {
        guard let token = KeychainManager.getAuthenticationToken() else {
            throw ArkavoError.authenticationFailed("No authentication token")
        }

        var request = URLRequest(url: authURL.appendingPathComponent("account"))
        request.httpMethod = "DELETE"
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await Self.http3Data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArkavoError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("Delete account failed with status \(httpResponse.statusCode): \(errorMessage)")
            throw ArkavoError.authenticationFailed("Failed to delete account: \(errorMessage)")
        }

        print("Account deleted successfully on server")

        // Disconnect and clear local auth state
        await disconnect()
    }

    /// Deletes the Arkavo account `accountName` (App Store guideline 5.1.1(v)).
    ///
    /// Only the account signed in on this device can be deleted: the stored
    /// handle must be `accountName`, and the stored token's `sub` names the
    /// account to re-authenticate. A passkey sign-in scoped to that account
    /// gets a fresh token, because the server accepts only one minted within
    /// 300 s; identity's reply must name `accountName` (and the token's `sub`,
    /// when readable, that account). Then `DELETE /account` is sent. A 409 is
    /// retried once with the same token; a 401 runs the sign-in once more,
    /// checked the same way, and retries once.
    ///
    /// After `.deleted` or `.alreadyDeleted` the system is told that identity
    /// accepts none of the account's passkeys, so they leave the device's list
    /// (best effort, never thrown).
    ///
    /// - Returns: `.deleted` when the server accepted the deletion, or
    ///   `.alreadyDeleted` when the sign-in found no such account.
    /// - Throws: `ArkavoError.invalidState` while another deletion runs or the
    ///   client is connecting or authenticating; `ArkavoError.invalidURL` for an
    ///   empty name or one with leading or trailing whitespace (a padded name
    ///   could find no account and be taken for an already deleted one);
    ///   `ArkavoError.notConnected`, with no sign-in, when this device holds no
    ///   session of `accountName` (no stored token, a token without an account
    ///   id, no stored handle, or another stored handle), or before the next
    ///   `DELETE` when a sign-in proved another account; the ceremony's own error
    ///   (`ASAuthorizationError.canceled` when the person cancels); otherwise
    ///   `ArkavoError.authenticationFailed("Account deletion failed")`.
    ///   Nothing is removed from this device when it throws.
    @MainActor
    public func deleteAccount(accountName: String) async throws -> AccountDeletionResult {
        guard !isDeletingAccount, currentState != .connecting, currentState != .authenticating else {
            throw ArkavoError.invalidState
        }
        let trimmedName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName == accountName else {
            throw ArkavoError.invalidURL
        }
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        // Read before the ceremony: the sign-in is scoped, and the wipe decides,
        // from what was stored then.
        let storedToken = credentialStore.authenticationToken()
        let storedHandle = credentialStore.sharedHandle()
        guard let account = Self.deletionAccount(named: accountName, storedToken: storedToken, storedHandle: storedHandle) else {
            print("ArkavoClient.deleteAccount: no stored session of this account; refused without a sign-in")
            throw ArkavoError.notConnected
        }

        let outcome = try await requestAccountDeletion(account: account, accountName: accountName)
        wipeLocalAccountState(
            after: outcome,
            accountName: accountName,
            storedToken: storedToken,
            storedHandle: storedHandle
        )
        // After the wipe, so a stalled report cannot hold it up.
        await credentialReporter.reportNoAcceptedCredentials(
            relyingPartyID: relyingPartyID,
            userHandle: withUnsafeBytes(of: account.uuid) { Data($0) }
        )
        return outcome.result
    }

    /// The account a deletion of `accountName` re-authenticates: the stored
    /// token's `sub` (read without a signature check; the passkey proves
    /// control), and only while the stored handle is `accountName`. nil when
    /// this device holds no session of that account, so a deletion never
    /// signs in to some other account.
    private static func deletionAccount(named accountName: String, storedToken: String?, storedHandle: String?) -> UUID? {
        guard storedHandle == accountName,
              let storedToken,
              let subject = CWTSubject.sub(fromToken: storedToken)
        else {
            return nil
        }
        return UUID(uuidString: subject)
    }

    /// Removes this device's copy of a deleted account. Best effort: every step
    /// runs whatever the others did. Only removing the DID key reports a
    /// failure, which is logged as its `KeychainError` (no secret); the other
    /// removals ignore theirs.
    ///
    /// The shared keychain items belong to every Arkavo app on the device, so
    /// they go only when they are this account's: the session token when its
    /// CWT `sub` is the fresh token's (or, when either `sub` is unreadable or
    /// there is no fresh token, under the handle condition); the shared handle,
    /// DID, local identity pair and DID key under the handle condition (the
    /// stored shared handle is nil or `accountName`).
    ///
    /// `deleteAccount` gets here only past its gate and its check of the
    /// sign-in: the stored handle is `accountName`, the stored token's `sub` is
    /// the deleted account, and so is the fresh token's when readable. So every
    /// item goes; these conditions are a second line of defence, should those
    /// checks change.
    private func wipeLocalAccountState(
        after outcome: DeletionOutcome,
        accountName: String,
        storedToken: String?,
        storedHandle: String?
    ) {
        tearDownSession()

        let handleIsThisAccount = storedHandle == nil || storedHandle == accountName
        if let storedToken,
           Self.storedToken(storedToken, belongsToAccountOf: outcome.freshToken, handleIsThisAccount: handleIsThisAccount)
        {
            credentialStore.deleteAuthenticationToken()
        }
        if handleIsThisAccount {
            credentialStore.deleteSharedHandleAndDID()
            credentialStore.deleteIdentityPair()
            do {
                try credentialStore.deleteDIDKey()
            } catch {
                // A KeychainError carries an OSStatus, no secret.
                print("ArkavoClient.deleteAccount: could not remove the DID key: \(error)")
            }
        }
        credentialStore.deleteAppleAccount()
    }

    /// Whether the stored session token is the deleted account's: the two CWT
    /// subjects match. When either is unreadable, or there is no fresh token
    /// (`.alreadyDeleted`), the handle condition decides.
    private static func storedToken(
        _ storedToken: String,
        belongsToAccountOf freshToken: String?,
        handleIsThisAccount: Bool
    ) -> Bool {
        guard let freshToken,
              let storedSubject = CWTSubject.sub(fromToken: storedToken),
              let freshSubject = CWTSubject.sub(fromToken: freshToken)
        else {
            return handleIsThisAccount
        }
        return storedSubject == freshSubject
    }

    /// Closes the socket and forgets the session without touching the keychain,
    /// whatever the connection state. (`disconnect()` runs only from
    /// `.connected` and always deletes the stored token.)
    private func tearDownSession() {
        webSocket?.cancel()
        webSocket = nil
        // A session retains its delegate until invalidated.
        session?.invalidateAndCancel()
        session = nil

        sessionSymmetricKey = nil
        keyPair = nil
        sharedSecret = nil
        salt = nil
        kasPublicKey = nil

        failPendingWaiters(ArkavoError.connectionFailed("Account deleted"))

        currentState = .disconnected
    }

    /// Fails every pending message handler and the pending connection with
    /// `error`. Both are cleared before any is resumed.
    private func failPendingWaiters(_ error: Error) {
        let handlers = messageHandlers.values
        messageHandlers.removeAll()
        let continuation = connectionContinuation
        connectionContinuation = nil
        for handler in handlers {
            handler.resume(throwing: error)
        }
        continuation?.resume(throwing: error)
    }

    /// What the server said about a deletion, and the token it said it to.
    private struct DeletionOutcome {
        let result: AccountDeletionResult
        /// The fresh token behind `.deleted`; nil for `.alreadyDeleted`.
        let freshToken: String?
    }

    private static let accountDeletionFailed = ArkavoError.authenticationFailed("Account deletion failed")

    /// The ceremony and `DELETE /account`, with one retry at most: a 409 again
    /// with the same token, a 401 with a new one. Both sign-ins re-authenticate
    /// `account` and must prove it is `accountName`. Never logs the token or a body.
    private func requestAccountDeletion(account: UUID, accountName: String) async throws -> DeletionOutcome {
        guard var token = try await freshDeletionToken(account: account, accountName: accountName) else {
            return DeletionOutcome(result: .alreadyDeleted, freshToken: nil)
        }

        var (data, status) = try await sendDeleteAccount(token: token)
        switch status {
        case 200 ... 299:
            return DeletionOutcome(result: .deleted(AccountDeletionReceipt.decode(data)), freshToken: token)
        case 409:
            break // a concurrent change on the server: retry with the same token
        case 401:
            guard let renewed = try await freshDeletionToken(account: account, accountName: accountName) else {
                return DeletionOutcome(result: .alreadyDeleted, freshToken: nil)
            }
            token = renewed
        default:
            throw Self.accountDeletionFailed
        }

        (data, status) = try await sendDeleteAccount(token: token)
        guard (200 ... 299).contains(status) else {
            throw Self.accountDeletionFailed
        }
        return DeletionOutcome(result: .deleted(AccountDeletionReceipt.decode(data)), freshToken: token)
    }

    /// The passkey ceremony for a deletion, scoped to `account`. nil when the
    /// server has no such account ("User Not Found"): it was already deleted.
    ///
    /// The stored token and handle are separate keychain items that every
    /// Arkavo app writes, so `account` may not be `accountName`'s. The sign-in
    /// must prove it is: identity's handle is `accountName`, and the fresh
    /// token's `sub`, when readable, is `account`. Otherwise it throws
    /// `ArkavoError.notConnected` before any `DELETE`. Every other error,
    /// `ASAuthorizationError.canceled` included, is rethrown unchanged.
    private func freshDeletionToken(account: UUID, accountName: String) async throws -> String? {
        let reply: AuthenticationReply
        do {
            reply = try await authenticator(account)
        } catch let ArkavoError.authenticationFailed(message) where message == "User Not Found" {
            return nil
        }
        let freshSubjectIsAccount = CWTSubject.sub(fromToken: reply.token).map { UUID(uuidString: $0) == account } ?? true
        guard reply.handle == accountName, freshSubjectIsAccount else {
            print("ArkavoClient.deleteAccount: the sign-in proved another account; refused before the deletion")
            throw ArkavoError.notConnected
        }
        return reply.token
    }

    /// Sends `DELETE /account` with `token` and returns the body and status.
    /// A transport error or a non-HTTP response is the generic failure.
    private func sendDeleteAccount(token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: authURL.appendingPathComponent("account"))
        request.httpMethod = "DELETE"
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpData(request)
        } catch {
            let nsError = error as NSError
            print("ArkavoClient.deleteAccount: transport error domain=\(nsError.domain) code=\(nsError.code)")
            throw Self.accountDeletionFailed
        }
        guard let http = response as? HTTPURLResponse else {
            throw Self.accountDeletionFailed
        }
        print("ArkavoClient.deleteAccount: status=\(http.statusCode)")
        return (data, http.statusCode)
    }

    public func sendMessage(_ data: Data) async throws {
        guard currentState == .connected, let webSocket else {
            throw ArkavoError.notConnected
        }
        // Check if the message is of type 0x06
        if let messageType = data.first, messageType == 0x06 {
            let maxSize = 2000 // Maximum allowed size for type 0x06
            if data.count > maxSize {
                print("Error: Outbound message type 0x06 exceeds maximum allowed size of \(maxSize) bytes")
                throw ArkavoError.messageError("Outbound message type 0x06 exceeds maximum allowed size")
            }
        }
        print("Sending WebSocket message:")
        print("Message type: 0x\(String(format: "%02X", data.first ?? 0))")
        print("Message length: \(data.count)")
        print("Raw data (hex): \(data.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " "))")
        try await webSocket.send(.data(data))
    }

    private func waitForMessage(type: ArkavoMessageType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.messageHandlers[type.rawValue] = continuation
            }
        }
    }

    private func sendInitialMessages() async throws {
        print("Beginning sendInitialMessages")
        guard let webSocket else {
            print("Error: WebSocket is nil")
            throw ArkavoError.notConnected
        }

        // Create key pair for the selected curve
        print("Creating key pair for curve: \(curve)")
        keyPair = try createKeyPair()
        print("Successfully created key pair")

        // Send public key
        let publicKeyMessage = PublicKeyMessage(publicKey: keyPair!.publicKeyData)
        print("Sending public key message, key length: \(publicKeyMessage.publicKey.count)")
        try await webSocket.send(.data(publicKeyMessage.toData()))
        print("Successfully sent public key message")

        // Wait for public key response
        do {
            print("Waiting for public key response...")
            let publicKeyData = try await waitForMessage(type: .publicKey)
            print("Received public key response, length: \(publicKeyData.count)")

            print("Processing public key response...")
            try handlePublicKeyResponse(data: publicKeyData)
            print("Successfully processed public key response")
            print("Salt length: \(salt?.count ?? 0)")
            print("Shared secret established: \(sharedSecret != nil)")
        } catch {
            print("Error handling public key response: \(error)")
            currentState = .error(error)
            throw error
        }

        // Send KAS key message
        print("Sending KAS key message")
        let kasKeyMessage = KASKeyMessage()
        try await webSocket.send(.data(kasKeyMessage.toData()))
        print("Successfully sent KAS key message")

        // Wait for KAS key response
        do {
            print("Waiting for KAS key response...")
            let kasKeyData = try await waitForMessage(type: .kasKey)
            print("Received KAS key response, length: \(kasKeyData.count)")

            print("Processing KAS key response...")
            try handleKASKeyResponse(data: kasKeyData)
            print("Successfully processed KAS key response")
        } catch {
            print("Error handling KAS key response: \(error)")
            currentState = .error(error)
            throw error
        }

        print("sendInitialMessages completed successfully")
    }

    // Helper method for sending messages and awaiting responses
    private func sendAndWait(_ message: some ArkavoMessage) async throws -> Data {
        try await webSocket?.send(.data(message.toData()))
        return try await waitForMessage(type: message.messageType)
    }

    // MARK: - Private Methods

    private func createKeyPair() throws -> CurveKeyPair {
        switch curve {
        case .p256:
            P256KeyPair(privateKey: P256.KeyAgreement.PrivateKey())
        case .p384:
            P384KeyPair(privateKey: P384.KeyAgreement.PrivateKey())
        case .p521:
            P521KeyPair(privateKey: P521.KeyAgreement.PrivateKey())
        }
    }

    private func handlePublicKeyResponse(data: Data) throws {
        print("handlePublicKeyResponse - Received data length: \(data.count)")

        guard data.first == 0x01 else {
            print("Error: Invalid message type byte: \(String(format: "0x%02X", data.first ?? 0))")
            throw ArkavoError.invalidResponse
        }

        let responseData = data.dropFirst()
        let expectedLength = curve.compressedKeySize + 32 // compressed public key + salt
        print("Expected response length: \(expectedLength), Actual length: \(responseData.count)")

        guard responseData.count == expectedLength else {
            print("Error: Response data length mismatch")
            throw ArkavoError.messageError("Invalid public key response length")
        }

        // Set session salt
        salt = responseData.suffix(32)
        let publicKeyData = responseData.prefix(curve.compressedKeySize)
        print("Extracted salt length: \(salt?.count ?? 0)")
        print("Extracted public key length: \(publicKeyData.count)")

        // Compute shared secret using the appropriate curve
        print("Computing shared secret...")
        sharedSecret = try keyPair?.computeSharedSecret(withPublicKeyData: publicKeyData)

        // Derive session symmetric key
        if let sharedSecret, let salt {
            sessionSymmetricKey = deriveSessionSymmetricKey(sharedSecret: sharedSecret, salt: salt)
        }

        print("Shared secret computation: \(sharedSecret != nil ? "successful" : "failed")")
    }

    // Helper method to derive the session symmetric key
    private func deriveSessionSymmetricKey(sharedSecret: SharedSecret, salt: Data) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("rewrappedKey".utf8),
            outputByteCount: 32
        )
    }

    // Helper method to decrypt rewrapped keys
    public func decryptRewrappedKey(nonce: Data, rewrappedKey: Data, authTag: Data, isV13: Bool = true) throws -> SymmetricKey {
        guard let sessionKey = sessionSymmetricKey else {
            throw ArkavoError.invalidState
        }

        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: rewrappedKey,
            tag: authTag
        )

        let decryptedDataSharedSecret = try AES.GCM.open(sealedBox, using: sessionKey)

        // The server sends the shared secret, not the final DEK
        // We need to derive the symmetric key using HKDF
        let sharedSecretKey = SymmetricKey(data: decryptedDataSharedSecret)

        // Use appropriate salt based on NanoTDF version
        let salt = isV13 ? Data("L1M".utf8) : Data("L1L".utf8)

        return deriveSymmetricKey(
            sharedSecretKey: sharedSecretKey,
            salt: salt,
            info: Data("encryption".utf8),
            outputByteCount: 32
        )
    }

    /// Decrypts a NanoTDF by coordinating with the KAS via WebSocket
    /// - Parameter nanoTDFData: The serialized NanoTDF data to decrypt
    /// - Returns: The decrypted plaintext
    /// - Throws: ArkavoError or decryption errors
    public func decryptNanoTDF(_ nanoTDFData: Data) async throws -> Data {
        // Step 1: Parse the NanoTDF
        let parser = BinaryParser(data: nanoTDFData)
        let header = try parser.parseHeader()
        let payload = try parser.parsePayload(config: header.payloadSignatureConfig)
        let signature = try parser.parseSignature(config: header.payloadSignatureConfig)
        let nanoTDF = NanoTDF(header: header, payload: payload, signature: signature)

        // Step 2: Send rewrap request to KAS
        let rewrapMessage = RewrapMessage(header: header)
        try await sendMessage(rewrapMessage.toData())

        // Step 3: Wait for rewrapped key response (0x04)
        let rewrappedData = try await waitForMessage(type: .rewrappedKey)

        // Step 4: Parse the rewrapped key response
        // Format: [1 byte type] + [32 bytes identifier] + [60 bytes key data]
        // Key data: [12 bytes nonce] + [32 bytes encrypted key] + [16 bytes auth tag]
        guard rewrappedData.count == 93 else {
            throw ArkavoError.messageError("Invalid rewrapped key response length: \(rewrappedData.count)")
        }

        let keyData = rewrappedData.suffix(60)
        let nonce = keyData.prefix(12)
        let encryptedKey = keyData.dropFirst(12).prefix(32)
        let authTag = keyData.suffix(16)

        // Step 5: Decrypt the rewrapped key to get the DEK
        let dek = try decryptRewrappedKey(
            nonce: nonce,
            rewrappedKey: encryptedKey,
            authTag: authTag,
            isV13: true
        )

        // Step 6: Decrypt the payload using the DEK
        let plaintext = try await nanoTDF.getPayloadPlaintext(symmetricKey: dek)

        return plaintext
    }

    private func handleKASKeyResponse(data: Data) throws {
        print("handleKASKeyResponse - Received data length: \(data.count)")

        guard data.first == 0x02 else {
            print("Error: Invalid message type byte: \(String(format: "0x%02X", data.first ?? 0))")
            throw ArkavoError.invalidResponse
        }

        let kasPublicKeyData = data.dropFirst()
        print("KAS public key length: \(kasPublicKeyData.count), Expected length: \(curve.compressedKeySize)")

        guard kasPublicKeyData.count == curve.compressedKeySize else {
            print("Error: KAS public key length mismatch")
            throw ArkavoError.messageError("Invalid KAS public key length")
        }

        // Validate KAS public key format
        print("Validating KAS public key format...")
        do {
            switch curve {
            case .p256:
                kasPublicKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: kasPublicKeyData)
            case .p384:
                _ = try P384.KeyAgreement.PublicKey(compressedRepresentation: kasPublicKeyData)
            case .p521:
                _ = try P521.KeyAgreement.PublicKey(compressedRepresentation: kasPublicKeyData)
            }
            print("KAS public key validation successful")
        } catch {
            print("Error validating KAS public key: \(error)")
            throw error
        }
    }

    // Helper method to derive a symmetric key
    public func deriveSymmetricKey(sharedSecretKey: SymmetricKey, salt: Data, info: Data, outputByteCount: Int = 32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecretKey,
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
    }

    /// The passkey assertion request, limited to the credentials the server's options
    /// list. A sign-in scoped to an account gets that account's, so the system sheet
    /// offers only its passkeys instead of every Arkavo passkey on the device. With no
    /// listed credentials (the name-free sign-in) the request stays open: any passkey
    /// for the relying party. An id that is not base64url is skipped.
    nonisolated static func passkeyAssertionRequest(
        provider: ASAuthorizationPlatformPublicKeyCredentialProvider,
        challenge: Data,
        allowCredentialIDs: [String]
    ) -> ASAuthorizationPlatformPublicKeyCredentialAssertionRequest {
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = allowCredentialIDs
            .compactMap { Data(base64Encoded: $0.base64URLToBase64()) }
            .map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
        return request
    }

    /// The passkey ceremony: `GET /authenticate`, the system sheet, then
    /// `POST /authenticate` with the assertion. Never stores the token.
    ///
    /// With no `account` it is the name-free sign-in: the sheet offers every passkey
    /// for the relying party, and identity names the account in its reply. With an
    /// `account` it re-authenticates that account, and the sheet offers only its passkeys.
    ///
    /// - Throws: `ArkavoError.authenticationFailed("User Not Found")` when the
    ///   scoped account no longer exists (the start's 500 `User Not Found`);
    ///   `ArkavoError.unknownPasskey` when identity does not know the picked
    ///   passkey (reported to the system first, best effort);
    ///   `ArkavoError.invalidResponse` for any other refused start or unusable
    ///   options; the sheet's `ASAuthorizationError` unchanged.
    func passkeyCeremony(account: UUID?) async throws -> AuthenticationReply {
        print("ArkavoClient.passkeyCeremony: start scoped=\(account != nil)")
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyID)

        var components = URLComponents(url: authURL.appendingPathComponent("authenticate"), resolvingAgainstBaseURL: true)
        if let account {
            components?.queryItems = [URLQueryItem(name: "account", value: account.uuidString.lowercased())]
        }
        guard let url = components?.url else {
            throw ArkavoError.invalidURL
        }

        let (data, response) = try await httpData(URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArkavoError.invalidResponse
        }
        print("ArkavoClient.passkeyCeremony: start status=\(httpResponse.statusCode)")
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            // "User Not Found" makes a deletion clear the account's passkeys from
            // the device, so only identity's own answer for a missing account
            // counts: a 500 with exactly that body, not a proxy's page or another route.
            if httpResponse.statusCode == 500,
               String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "User Not Found"
            {
                throw ArkavoError.authenticationFailed("User Not Found")
            }
            throw ArkavoError.invalidResponse
        }

        guard let options = try? JSONDecoder().decode(AuthenticationOptionsResponse.self, from: data),
              let challenge = Data(base64Encoded: options.publicKey.challenge.base64URLToBase64())
        else {
            throw ArkavoError.invalidResponse
        }

        let assertionRequest = Self.passkeyAssertionRequest(
            provider: provider,
            challenge: challenge,
            allowCredentialIDs: options.publicKey.publicKeyCredentialIDs
        )
        let assertion = try await assertionProvider(assertionRequest)

        var finishRequest = URLRequest(url: authURL.appendingPathComponent("authenticate"))
        finishRequest.httpMethod = "POST"
        finishRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let parameters: [String: Any] = [
            "id": assertion.credentialID.base64URLEncodedString(),
            "rawId": assertion.credentialID.base64URLEncodedString(),
            "response": [
                "clientDataJSON": assertion.rawClientDataJSON.base64URLEncodedString(),
                "authenticatorData": assertion.rawAuthenticatorData.base64URLEncodedString(),
                "signature": assertion.signature.base64URLEncodedString(),
                "userHandle": assertion.userID?.base64URLEncodedString() ?? "",
            ],
            "type": "public-key",
        ]
        finishRequest.httpBody = try JSONSerialization.data(withJSONObject: parameters)

        let (replyData, finishResponse) = try await httpData(finishRequest)
        guard let finishHTTPResponse = finishResponse as? HTTPURLResponse else {
            throw ArkavoError.authenticationFailed("Invalid response from server")
        }
        print("ArkavoClient.passkeyCeremony: finish status=\(finishHTTPResponse.statusCode)")
        let replyText = String(decoding: replyData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch finishHTTPResponse.statusCode {
        case 200 ... 299:
            break
        // Only identity's own refusal reports the passkey: a 404 from anywhere
        // else must not remove a passkey from the person's device.
        case 404 where replyText == "Unknown Passkey":
            await credentialReporter.reportUnknown(relyingPartyID: relyingPartyID, credentialID: assertion.credentialID)
            throw ArkavoError.unknownPasskey
        // Unreachable from this client: the start sends no X-Auth-Token, and a scoped finish answers a foreign handle with 400.
        case 403:
            throw ArkavoError.authenticationFailed("Passkey belongs to another account")
        default:
            throw ArkavoError.authenticationFailed("Invalid response from server")
        }

        let json = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any]
        guard let token = json?["token"] as? String, !token.isEmpty else {
            throw ArkavoError.authenticationFailed("No authentication token received")
        }
        guard let handle = json?["handle"] as? String, !handle.isEmpty else {
            throw ArkavoError.authenticationFailed("No account handle received")
        }
        return AuthenticationReply(token: token, handle: handle)
    }

    private func setupWebSocketConnection() async throws {
        print("Current state before WebSocket setup: \(currentState)")
        guard currentState == .connecting else {
            print("Invalid state for WebSocket setup: \(currentState)")
            throw ArkavoError.invalidState
        }

        print("ArkavoClient: Reading authentication token from Keychain (com.arkavo.webauthn/authentication_token)")
        guard let token = KeychainManager.getAuthenticationToken() else {
            print("ArkavoClient: No authentication token found in Keychain (treating as signed-out state)")
            currentState = .error(ArkavoError.authenticationFailed("No authentication token"))
            throw ArkavoError.authenticationFailed("No authentication token")
        }

        let wsURL = websocketURL
        print("\nWebSocket Connection Attempt:")
        print("URL: \(wsURL)")

        var request = URLRequest(url: wsURL)
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        request.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")

//        print("\nRequest Headers:")
//        dump(request.allHTTPHeaderFields ?? [:])

        let session = URLSession(configuration: .default, delegate: socketDelegate, delegateQueue: delegateQueue)
        self.session = session

        let webSocket = session.webSocketTask(with: request)
        self.webSocket = webSocket

        webSocket.sendPing { [weak self, weak webSocket] error in
            guard let self, let webSocket else { return }

            Task { @MainActor in
                self.handleInitialPingResult(error, from: webSocket)
            }
        }

        print("\nWebSocket Task Created: \(webSocket)")
        webSocket.resume()
        receiveMessage()
    }

    /// Handles the reply to the first ping on `task`: a failure fails the
    /// pending connection and sets `.error`. Dropped when `task` is no longer
    /// `webSocket`: a ping still outstanding when its socket was cancelled
    /// fails, and that failure is not the current connection's. Internal so
    /// tests can drive it.
    func handleInitialPingResult(_ error: Error?, from task: URLSessionWebSocketTask) {
        guard task === webSocket else { return }
        if let error {
            print("Initial ping failed: \(error)")
            if let continuation = connectionContinuation {
                connectionContinuation = nil
                continuation.resume(throwing: error)
            }
            currentState = .error(error)
        } else {
            print("Initial ping successful")
        }
    }

    private func receiveMessage() {
//        print("receiveMessage")
        guard let webSocket else {
            print("WebSocket is nil, cannot receive message")
            return
        }

        webSocket.receive { [weak self, weak webSocket] result in
            guard let self, let webSocket else { return }

            Task { @MainActor in
                await self.handleReceiveResult(result, from: webSocket)
            }
        }
    }

    /// Handles what `receive` on `task` returned. Dropped when `task` is no
    /// longer `webSocket`: the receive of a cancelled socket fails, and that
    /// failure is not the current connection's. Internal so tests can drive it.
    func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>, from task: URLSessionWebSocketTask) async {
        guard task === webSocket else { return }

        switch result {
        case let .success(message):
//            print("\n=== Received WebSocket Message ===")
//            print("Message type: \(message)")
            switch message {
            case let .data(data):
                await handleIncomingMessage(data)
            case let .string(string):
                print("Received string message: \(string)")
            @unknown default:
                print("Received unknown message type \(message)")
            }

        case let .failure(error):
            print("WebSocket receive error: \(error)")
            currentState = .error(error)
            delegate?.clientDidReceiveError(self, error: error)

            // Resume any waiting continuations with error
            for continuation in messageHandlers.values {
                continuation.resume(throwing: error)
            }
            messageHandlers.removeAll()
        }

        // Continue receiving messages if still connected
        if currentState == .connected {
            receiveMessage()
        }
    }

    // New message handling function
    private func handleIncomingMessage(_ data: Data) async {
        guard let messageType = data.first else {
            print("Invalid message: empty data")
            return
        }

        print("Received data message:")
        print("Length: \(data.count) bytes")
        print("Message type: 0x\(String(format: "%02X", messageType))")
        print("Raw data (hex): \(data.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Validate message size for type 0x06
        if messageType == 0x06 {
            let maxSize = 2000 // Maximum allowed size for type 0x06
            if data.count > maxSize {
                print("Error: Message type 0x06 exceeds maximum allowed size of \(maxSize) bytes")
                delegate?.clientDidReceiveError(self, error: ArkavoError.messageError("Message type 0x06 exceeds maximum allowed size"))
                return
            }
        }

        // Handle continuation-based messages first
        if let continuation = messageHandlers.removeValue(forKey: messageType) {
            continuation.resume(returning: data)
            return
        }

        // Then handle via delegate
        delegate?.clientDidReceiveMessage(self, message: data)
    }

    private func handleRewrappedKeyMessage(_ data: Data) {
//        print("ArkavoClient: Handling rewrapped key message of length: \(data.count)")
        guard data.count == 93 else {
            if data.count == 33 {
                // DENY -- Notify the app with the identifier
                delegate?.clientDidReceiveMessage(self, message: data)
                return
            }
            print("RewrappedKeyMessage not the expected 93 bytes: \(data.count)")
            return
        }

        let keyData = data.suffix(60)
        // Parse key data components
        let encryptedKeyLength = keyData.count - 12 - 16 // Total - nonce - tag

        guard encryptedKeyLength >= 0 else {
            print("Invalid encrypted key length: \(encryptedKeyLength)")
            return
        }
        // Process the rewrapped key...
        // (Implementation specific to your needs)
        delegate?.clientDidReceiveMessage(self, message: data)
    }

    // Add methods to send NATS messages
    public func sendNATSMessage(_ payload: Data) async throws {
        let message = NATSMessage(message: payload)
        try await sendMessage(message.toData())
    }

    public func sendNATSEvent(_ payload: Data) async throws {
        let message = NATSEvent(message: payload)
        try await sendMessage(message.toData())
    }

    /// Fetches a profile using the actor's handle (e.g. "username.arkavo.social")
    public func fetchProfile(forHandle handle: String) async throws -> ArkavoProfile {
        guard !handle.isEmpty else {
            throw ArkavoError.invalidURL
        }

        var components = URLComponents(string: "https://xrpc.arkavo.net/xrpc/app.arkavo.actor.getProfile")
        components?.queryItems = [URLQueryItem(name: "actor", value: handle)]

        guard let url = components?.url else {
            throw ArkavoError.invalidURL
        }

        let (data, response) = try await Self.http3Data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArkavoError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            return try decoder.decode(ArkavoProfile.self, from: data)
        case 404:
            throw ArkavoError.profileNotFound("Profile not found for handle: \(handle)")
        default:
            throw ArkavoError.invalidResponse
        }
    }

    /// Fetches a profile using a 32-byte public ID
    public func fetchProfile(forPublicID publicID: Data) async throws -> ArkavoProfile {
        // Check cache first
        if let cachedProfile = profileCache.get(publicID) {
            return cachedProfile
        }

        var components = URLComponents(string: "https://xrpc.arkavo.net/xrpc/app.arkavo.actor.getProfile")
        components?.queryItems = [URLQueryItem(name: "actor", value: publicID.base58String)]

        guard let url = components?.url else {
            throw ArkavoError.invalidURL
        }

        let (data, response) = try await Self.http3Data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArkavoError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            let profile = try decoder.decode(ArkavoProfile.self, from: data)
            // Cache the profile
            profileCache.set(publicID, value: profile)
            return profile
        case 404:
            throw ArkavoError.profileNotFound("Profile not found for ID: \(publicID.base58String)")
        default:
            print("statusCode: \(httpResponse.statusCode) response: \(String(decoding: data, as: UTF8.self))")
            throw ArkavoError.invalidResponse
        }
    }

    /// Register a new user with WebAuthn
    public func registerUser(handle: String, did: String) async throws -> String {
        guard !isDeletingAccount else { throw ArkavoError.invalidState }
        print("Initiating user registration with handle: \(handle)")

        // Admission control: the server refuses registration without a
        // ticket issued against a verified App Attest attestation.
        try await performAttestationPreflight()

        do {
            return try await performRegistrationCeremony(handle: handle, did: did)
        } catch is RegistrationTicketExpired {
            // The App Attest ticket lives in the session and can expire
            // between attest and finish. Re-attest once and repeat the
            // *entire* ceremony (fresh options, fresh challenge) rather
            // than reusing state from the expired attempt — a second
            // expiry surfaces to the caller instead of retrying forever.
            print("Registration ticket expired between attest and finish; retrying the ceremony once")
            try await performAttestationPreflight()
            do {
                return try await performRegistrationCeremony(handle: handle, did: did)
            } catch {
                throw Self.mapDuplicatePasskeyError(error, relyingPartyID: relyingPartyID)
            }
        } catch {
            throw Self.mapDuplicatePasskeyError(error, relyingPartyID: relyingPartyID)
        }
    }

    /// The full WebAuthn registration ceremony: fetch options, create the
    /// platform credential, and finish with the server. Pulled out of
    /// `registerUser` so the ticket-expiry retry re-runs the whole thing —
    /// including a fresh challenge — instead of replaying a credential
    /// request built against options tied to the expired ticket.
    private func performRegistrationCeremony(handle: String, did: String) async throws -> String {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyID)

        let registrationOptions = try await fetchRegistrationOptions(
            handle: handle,
            did: did
        )

        guard let challengeData = Data(base64Encoded: registrationOptions.challenge.base64URLToBase64()) else {
            throw ArkavoError.authenticationFailed("Failed to decode challenge data from base64")
        }

        guard let userIDData = Data(base64Encoded: registrationOptions.userID.base64URLToBase64()) else {
            throw ArkavoError.authenticationFailed("Failed to decode userID data from base64")
        }

        print("Registration request prepared: \(userIDData.count) bytes userID, \(challengeData.count) bytes challenge")
        print("Creating credential registration request for handle: \(handle)")

        let credentialRequest = provider.createCredentialRegistrationRequest(
            challenge: challengeData,
            name: handle,
            userID: userIDData
        )

        print("Credential request created, calling performRegistration")
        let credential = try await performRegistration(request: credentialRequest)
        print("performRegistration succeeded, completing registration")
        return try await completeRegistration(
            credential: credential,
            handle: handle,
            did: did
        )
    }

    /// Recognizes the keychain's duplicate-passkey error (errSecDuplicateItem,
    /// -25300) and rewrites it with recovery guidance a user can act on;
    /// every other error passes through unchanged.
    private static func mapDuplicatePasskeyError(_ error: Error, relyingPartyID: String) -> Error {
        print("performRegistration threw error: \(error)")
        let nsError = error as NSError
        print("Error details: domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription)")

        guard nsError.code == -25300 else {
            return error
        }

        print("Detected errSecDuplicateItem (-25300)")
        return NSError(
            domain: "ArkavoRegistration",
            code: -25300,
            userInfo: [
                NSLocalizedDescriptionKey: "A passkey already exists for this relying party",
                NSLocalizedRecoverySuggestionErrorKey: """
                A passkey for '\(relyingPartyID)' already exists on this device.

                To register a new account:
                1. Open Settings → Passwords
                2. Search for '\(relyingPartyID)'
                3. Delete all existing passkeys
                4. Return to Arkavo and try again

                Or try using a different username.

                Technical details: The passkey system prevents duplicate credentials.
                Each device can have multiple passkeys for the same site, but they
                must have different user IDs. If you're seeing this error repeatedly,
                the server may be generating the same user ID for different usernames.
                """,
                NSLocalizedFailureReasonErrorKey: "errSecDuplicateItem: Duplicate passkey detected"
            ]
        )
    }

    private func fetchRegistrationOptions(
        handle: String,
        did: String
    ) async throws -> (challenge: String, userID: String) {
        // Build URL with query parameters
        var components = URLComponents(url: authURL.appendingPathComponent("register/\(handle)"), resolvingAgainstBaseURL: true)
        components?.queryItems = [
            URLQueryItem(name: "handle", value: handle),
            URLQueryItem(name: "did", value: did),
        ]

        guard let url = components?.url else {
            throw ArkavoError.invalidURL
        }

        let (data, response) = try await Self.http3Data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            print("fetchRegistrationOptions.invalidResponse \(String(decoding: data, as: UTF8.self))")
            throw ArkavoError.invalidResponse
        }

        let decoder = JSONDecoder()
        let options = try decoder.decode(RegistrationOptionsResponse.self, from: data)

        return (options.publicKey.challenge, options.publicKey.user.id)
    }

    private func performRegistration(request: ASAuthorizationRequest) async throws -> ASAuthorizationPlatformPublicKeyCredentialRegistration {
        try await withCheckedThrowingContinuation { continuation in
            print("performRegistration")
            let controller = ASAuthorizationController(authorizationRequests: [request])
            let delegate = WebAuthnRegistrationDelegate(continuation: continuation)
            controller.delegate = delegate
            controller.presentationContextProvider = self

            // Retain delegate until registration completes
            objc_setAssociatedObject(controller, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

            controller.performRequests()
        }
    }

    func performAuthentication(request: ASAuthorizationRequest) async throws -> ASAuthorizationPlatformPublicKeyCredentialAssertion {
        try await withCheckedThrowingContinuation { continuation in
            print("\n=== WebAuthn Authentication ===")
            print("Starting performAuthentication")

            let controller = ASAuthorizationController(authorizationRequests: [request])
            let delegate = WebAuthnAuthenticationDelegate(continuation: continuation)
            controller.delegate = delegate
            controller.presentationContextProvider = self

            // Retain delegate until authentication completes
            objc_setAssociatedObject(controller, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

            print("Performing authorization requests...")
            controller.performRequests()
            print("=== End WebAuthn Authentication Setup ===\n")
        }
    }

    private func completeRegistration(
        credential: ASAuthorizationPlatformPublicKeyCredentialRegistration,
        handle: String,
        did: String
    ) async throws -> String {
        var request = URLRequest(url: authURL.appendingPathComponent("register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String: Any] = [
            // WebAuthn credential data
            "id": credential.credentialID.base64URLEncodedString(),
            "rawId": credential.credentialID.base64URLEncodedString(),
            "response": [
                "clientDataJSON": credential.rawClientDataJSON.base64URLEncodedString(),
                "attestationObject": credential.rawAttestationObject!.base64URLEncodedString(),
            ],
            "type": "public-key",

            // Additional Arkavo registration data
            "handle": handle,
            "did": did,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)

        let (data, response) = try await Self.http3Data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArkavoError.authenticationFailed("No HTTP response received")
        }

        // The App Attest ticket backing this registration lives in the
        // session and has a short TTL. A 403 here (distinct from the
        // register-attest 403, which is a lifetime cap) means the ticket
        // expired between attest and finish — the caller re-attests and
        // retries the ceremony once.
        if httpResponse.statusCode == 403 {
            throw RegistrationTicketExpired()
        }

        guard let token = httpResponse.allHeaderFields["x-auth-token"] as? String else {
            // If we got an error response, try to parse it
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorJson["error"] as? String
            {
                throw ArkavoError.authenticationFailed(errorMessage)
            }
            throw ArkavoError.authenticationFailed("No authentication token received")
        }

        // Token is a base64url-encoded CWT (CBOR tag 61 wrapping COSE_Sign1).
        // No client-side format gate — server is the authority. Trim padding/whitespace just in case.
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Signals that the App Attest ticket backing this registration attempt
    /// expired before `completeRegistration` could redeem it. Kept as its
    /// own type (not folded into `ArkavoError`) so `registerUser` can catch
    /// exactly this case to retry once, without also swallowing other
    /// `authenticationFailed` failures that should not be retried.
    private struct RegistrationTicketExpired: Error {}

    // MARK: - App Attest registration gate
    //
    // The server refuses `register/:username` without a ticket issued
    // against a verified App Attest attestation. This runs the full
    // challenge -> attest -> verify round trip:
    //   1. GET  device-check/register-challenge  (no auth; sets the
    //      session cookie the ticket will live in)
    //   2. Generate + attest a key locally (AppAttestPreflight)
    //   3. POST device-check/register-attest with the attestation
    // On success the generated key_id is stashed in the Keychain because
    // App Attest keys are minted once and cannot be re-attested: a later
    // sign-in that asserts this device has to reuse this exact key rather
    // than mint a fresh one. Nothing reads it back yet — the server
    // exposes `device-check/assert-challenge/:username` and
    // `device-check/assert`, but no client-side assertion flow calls
    // them, so for now this persist only preserves the option.
    //
    // Like the Apple-link flow above, these calls stay on `Self.http3Data`
    // (`identitySession`) so the session cookie set by step 1 is replayed
    // automatically in step 3 and in the `register/:username` calls that
    // follow.

    private func performAttestationPreflight() async throws {
        let challenge = try await fetchDeviceAttestChallenge()

        let result = try await AppAttestPreflight().keyAndAttestation(challenge: challenge)

        try await submitAttestation(
            keyID: result.keyID,
            attestation: result.attestation,
            clientDataHash: result.clientDataHash
        )

        // Persisted only after the server accepts the attestation — an
        // earlier persist could stash a key_id the server never verified.
        //
        // Best-effort on purpose. The server has already admitted this
        // registration by the time we get here, so throwing would fail a
        // registration the server accepted — and for a value nothing reads
        // back yet (there is no client-side assertion flow). A Keychain
        // failure is worth a log, not a lost registration.
        do {
            try KeychainManager.saveDeviceAttestKeyID(result.keyID)
        } catch {
            print("Failed to persist device attest key_id (registration continues): \(error)")
        }
    }

    private func fetchDeviceAttestChallenge() async throws -> String {
        let url = authURL.appendingPathComponent("device-check/register-challenge")
        let (data, response) = try await Self.http3Data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw AppAttestError.attestationRejected(
                "register-challenge failed: \(String(decoding: data, as: UTF8.self))"
            )
        }

        let decoded = try JSONDecoder().decode(DeviceAttestChallengeResponse.self, from: data)
        return decoded.challenge
    }

    private func submitAttestation(keyID: String, attestation: Data, clientDataHash: Data) async throws {
        var request = URLRequest(url: authURL.appendingPathComponent("device-check/register-attest"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Standard base64 (not base64url) per the device-check contract —
        // distinct from the base64url WebAuthn payloads elsewhere in this file.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key_id": keyID,
            "attestation_object": attestation.base64EncodedString(),
            "client_data_hash": clientDataHash.base64EncodedString(),
        ])

        let (data, response) = try await Self.http3Data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppAttestError.attestationRejected("register-attest: no HTTP response received")
        }

        guard !(200 ... 299).contains(httpResponse.statusCode) else { return }

        // Branch on the error token, never on the status alone. The contract
        // (authnz-rs docs/app-attest-preflight-contract.md) makes
        // `attest_registration_cap` the *only* permanent refusal, and puts the
        // server-misconfiguration case on 503 `app_id_not_configured`
        // specifically so a fail-closed deploy cannot be mistaken for a barred
        // device. An unrecognized or missing token is therefore retryable:
        // without the token there is not enough evidence for a verdict the
        // user can never recover from.
        let code = Self.errorCode(from: data)
        let detail = Self.errorDescription(from: data)
            ?? code
            ?? String(decoding: data, as: UTF8.self)

        if Self.isPermanentRefusal(code) {
            throw AppAttestError.registrationCapExceeded
        }

        // Retry-After is read only for the rate-limit code, and only as a
        // fallback on a bare 429. Both paths are retryable, so leaning on the
        // status here cannot produce a permanent verdict — the one outcome
        // the status alone must never reach.
        if code == Self.errorCodeRateLimited || (code == nil && httpResponse.statusCode == 429),
           let retryAfterValue = httpResponse.value(forHTTPHeaderField: "Retry-After"),
           let retryAfter = TimeInterval(retryAfterValue)
        {
            throw AppAttestError.rateLimited(retryAfter: retryAfter)
        }

        throw AppAttestError.attestationRejected(detail)
    }

    /// The one refusal from `register-attest` that can never clear: this
    /// `key_id` has spent its lifetime registration budget.
    nonisolated static let errorCodePermanentCap = "attest_registration_cap"
    /// The per-key rolling-window refusal. Temporary; carries `Retry-After`.
    nonisolated static let errorCodeRateLimited = "attest_rate_limited"

    /// Pulls the server's stable `{"error": "<code>"}` token out of a response
    /// body, or nil when the body isn't that shape. Task 5 emits JSON on these
    /// routes; until it lands the body is plain text and this is nil, which
    /// keeps every refusal retryable by default.
    nonisolated static func errorCode(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    /// The human-readable companion to `errorCode`. For logs and display only
    /// — the contract states it may change, so nothing branches on it.
    nonisolated static func errorDescription(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
    }

    /// Whether a refusal is the permanent one. Exact-match on the contract's
    /// token: anything else — including an unrecognized code, a bodyless
    /// response, or the 503 `app_id_not_configured` that a fail-closed server
    /// returns — stays retryable.
    nonisolated static func isPermanentRefusal(_ code: String?) -> Bool {
        code == errorCodePermanentCap
    }

    public func encryptRemotePolicy(
        payload: Data,
        remotePolicyBody: String
    ) async throws -> Data {
        // Create Nano
        let kasRL = ResourceLocator(protocolEnum: .sharedResourceDirectory, body: "kas.arkavo.net")!
        let kasMetadata = try KasMetadata(
            resourceLocator: kasRL,
            publicKey: kasPublicKey as Any,
            curve: .secp256r1
        )

        let remotePolicy = ResourceLocator(
            protocolEnum: .sharedResourceDirectory,
            body: remotePolicyBody
        )!

        var policy = Policy(
            type: .remote,
            body: nil,
            remote: remotePolicy,
            binding: nil
        )

        let nanoTDF = try await createNanoTDF(
            kas: kasMetadata,
            policy: &policy,
            plaintext: payload
        )

        return nanoTDF.toData()
    }

    /// Encrypts a payload with a policy and sends it via a NATS message.
    public func encryptAndSendPayload(
        payload: Data,
        policyData: Data,
        kasMetadata: KasMetadata? = nil
    ) async throws -> Data {
        let kasMetadataDefault = try KasMetadata(
            resourceLocator: ResourceLocator(protocolEnum: .sharedResourceDirectory, body: "kas.arkavo.net")!,
            publicKey: kasPublicKey as Any,
            curve: .secp256r1
        )
        let kasMetadata = kasMetadata ?? kasMetadataDefault
        var policy = Policy(
            type: .embeddedPlaintext,
            body: EmbeddedPolicyBody(body: policyData),
            remote: nil,
            binding: nil
        )

        // Create NanoTDF
        let nanoTDF = try await createNanoTDF(
            kas: kasMetadata,
            policy: &policy,
            plaintext: payload
        )

        // Send via NATS message
        let natsMessage = NATSMessage(message: nanoTDF.toData())
        try await sendMessage(natsMessage.toData())

        return nanoTDF.toData()
    }

    // MARK: - Apple identity linking
    //
    // Two-step contract against the identity server:
    //   1. GET  /oauth/apple/nonce  — server issues a fresh nonce, stores
    //      it against the session cookie (10-min TTL, single-use).
    //   2. POST /oauth/apple/link   — client posts the verified Apple
    //      id_token; server validates and binds (apple, sub) → user_id.
    //
    // Both calls go through `identitySession` so the session cookie set
    // in step 1 is automatically replayed in step 2.

    /// Fetches a fresh server-issued Apple nonce for the SiwA flow.
    /// The raw value must be SHA-256 hashed (hex) before being set as
    /// `ASAuthorizationAppleIDRequest.nonce`.
    public func fetchAppleNonce() async throws -> String {
        let url = authURL.appendingPathComponent("oauth/apple/nonce")
        print("ArkavoClient.fetchAppleNonce: GET \(url.absoluteString)")
        let (data, response) = try await Self.http3Data(from: url)

        guard let http = response as? HTTPURLResponse else {
            print("ArkavoClient.fetchAppleNonce: non-HTTP response")
            throw AppleLinkError.invalidResponse
        }
        print("ArkavoClient.fetchAppleNonce: status=\(http.statusCode) bodyLen=\(data.count)")
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            print("ArkavoClient.fetchAppleNonce: server error body=\(body.prefix(500))")
            throw AppleLinkError.serverError(http.statusCode, body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nonce = json["nonce"] as? String
        else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            print("ArkavoClient.fetchAppleNonce: invalid response body=\(body.prefix(500))")
            throw AppleLinkError.invalidResponse
        }
        return nonce
    }

    /// Posts the verified Apple id_token to `/oauth/apple/link`. Binds the
    /// Apple `sub` claim to the currently-authenticated arkavo account
    /// (identified by the CWT in the shared keychain).
    ///
    /// Throws [`AppleLinkError.conflict`] if this Apple identity is already
    /// linked to a different arkavo account.
    ///
    /// Sends no authorization code. A server that requires one (so it can
    /// revoke the Apple token when the account is deleted) answers 400.
    @available(*, deprecated, message: "Pass the credential's authorizationCode: linkAppleIdentity(idToken:authorizationCode:)")
    public func linkAppleIdentity(idToken: String) async throws {
        try await linkAppleIdentity(idToken: idToken, authorizationCode: nil)
    }

    /// Posts the verified Apple id_token, and the authorization code when there
    /// is one, to `/oauth/apple/link`. The server exchanges the code for a
    /// refresh token it can revoke when the Arkavo account is deleted (TN3194);
    /// a server without that support ignores the field.
    ///
    /// Pass `ASAuthorizationAppleIDCredential.authorizationCode` decoded as UTF-8.
    /// Throws `ArkavoError.invalidState` while an account deletion is running.
    public func linkAppleIdentity(idToken: String, authorizationCode: String?) async throws {
        guard !isDeletingAccount else { throw ArkavoError.invalidState }
        guard let cwt = credentialStore.authenticationToken() else {
            print("ArkavoClient.linkAppleIdentity: no CWT in keychain (missingAuthToken)")
            throw AppleLinkError.missingAuthToken
        }

        let url = authURL.appendingPathComponent("oauth/apple/link")
        print("ArkavoClient.linkAppleIdentity: POST \(url.absoluteString) cwtLen=\(cwt.count) idTokenLen=\(idToken.count)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cwt, forHTTPHeaderField: "X-Auth-Token")
        var payload = ["id_token": idToken]
        if let authorizationCode {
            payload["authorization_code"] = authorizationCode
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpData(request)
        } catch {
            print("ArkavoClient.linkAppleIdentity: network error \(error)")
            throw AppleLinkError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            print("ArkavoClient.linkAppleIdentity: non-HTTP response")
            throw AppleLinkError.invalidResponse
        }

        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        print("ArkavoClient.linkAppleIdentity: status=\(http.statusCode) bodyLen=\(data.count) body=\(body.prefix(500))")

        switch http.statusCode {
        case 200 ... 299:
            return
        case 400:
            throw AppleLinkError.sessionExpired
        case 401:
            throw AppleLinkError.unauthorized
        case 409:
            throw AppleLinkError.conflict
        default:
            throw AppleLinkError.serverError(http.statusCode, body)
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension ArkavoClient: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
            else {
                fatalError("No window found in the current window scene")
            }
            return window
        #elseif os(macOS)
            // Use the key window to properly anchor the passkey prompt,
            // especially when sheets are presented
            guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else {
                fatalError("No window found in the application")
            }
            return window
        #else
            fatalError("Unsupported platform")
        #endif
    }
}

// MARK: - DID Key Management Extension

public extension ArkavoClient {
    func generateDID() throws -> String {
        try KeychainManager.generateAndSaveDIDKey()
    }

    // TODO: Function to sign NanoTDF with DID
    // TODO: Function to verify NanoTDF with DID
}

// MARK: - Patreon Account Linking

public extension ArkavoClient {
    /// Links a Patreon account using an OAuth authorization code.
    /// The backend exchanges the code for tokens, fetches the user's tier,
    /// and returns an updated CWT with the SubscriptionTier attribute.
    ///
    /// - Parameter authorizationCode: The OAuth authorization code from Patreon
    /// - Throws: ArkavoError if linking fails
    static func linkPatreonAccount(authorizationCode: String) async throws {
        guard let token = KeychainManager.getAuthenticationToken() else {
            throw ArkavoError.authenticationFailed("No authentication token")
        }

        let url = ArkavoConfiguration.shared.identityURL.appendingPathComponent("link/patreon")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "authorization_code": authorizationCode,
            "redirect_uri": ArkavoConfiguration.shared.oauthRedirectURL(for: "patreon", client: "arkavo"),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.http3Data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArkavoError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ArkavoError.authenticationFailed("Patreon linking failed: \(errorMessage)")
        }

        // Parse response and save updated CWT
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["token"] as? String
        else {
            throw ArkavoError.authenticationFailed("No updated token received")
        }

        // Save the updated token with tier attributes
        try KeychainManager.saveAuthenticationToken(newToken)
    }
}

// MARK: - Helper Classes

private class AuthenticationDelegate: NSObject, ASAuthorizationControllerDelegate {
    private let continuation: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialRegistration, Error>

    init(continuation: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialRegistration, Error>) {
        self.continuation = continuation
    }

    func authorizationController(controller _: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            continuation.resume(throwing: ArkavoError.authenticationFailed("Invalid credential type"))
            return
        }
        continuation.resume(returning: credential)
    }

    func authorizationController(controller _: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation.resume(throwing: error)
    }
}

// MARK: - WebSocket Delegate

private actor WebSocketStateHandler {
    var stateHandler: ((ArkavoClientState, URLSessionTask) async -> Void)?

    func updateHandler(_ handler: @escaping (ArkavoClientState, URLSessionTask) -> Void) {
        stateHandler = handler
    }

    func handleState(_ state: ArkavoClientState, from task: URLSessionTask) async {
        await stateHandler?(state, task)
    }
}

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.arkavo.websocket.state")
    private let stateHandler = WebSocketStateHandler()
    private var _onConnect: (() -> Void)?

    var onConnect: (() -> Void)? {
        get { stateQueue.sync { _onConnect } }
        set { stateQueue.sync { _onConnect = newValue } }
    }

    func setStateHandler(_ handler: @Sendable @escaping (ArkavoClientState, URLSessionTask) -> Void) {
        Task {
            await stateHandler.updateHandler(handler)
        }
    }

    public func urlSession(_: URLSession,
                           webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?)
    {
        print("WebSocket did connect with protocol: \(`protocol` ?? "none")")
        onConnect?()
        Task {
            await stateHandler.handleState(.connected, from: webSocketTask)
        }
    }

    public func urlSession(_: URLSession,
                           task: URLSessionTask,
                           didCompleteWithError error: Error?)
    {
        Task {
            if let error {
                print("WebSocket did complete with error: \(error)")
                await stateHandler.handleState(.error(error), from: task)
            } else {
                print("WebSocket did complete normally")
                await stateHandler.handleState(.disconnected, from: task)
            }
        }
    }
}

// MARK: - App Attest Response Models

private struct DeviceAttestChallengeResponse: Decodable {
    let challenge: String
}

// MARK: - WebAuthn Response Models

private struct RegistrationOptionsResponse: Decodable {
    let publicKey: PublicKeyCredentialCreationOptions
}

private struct PublicKeyCredentialCreationOptions: Decodable {
    let challenge: String
    let rp: RelyingParty
    let user: User
    let pubKeyCredParams: [PublicKeyCredentialParameters]
    let timeout: Int?
    let attestation: String?
    let excludeCredentials: [PublicKeyCredentialDescriptor]?
    let authenticatorSelection: AuthenticatorSelectionCriteria?
}

private struct RelyingParty: Decodable {
    let name: String
    let id: String
}

private struct User: Decodable {
    let id: String
    let name: String
    let displayName: String
}

private struct PublicKeyCredentialParameters: Decodable {
    let alg: Int
    let type: String
}

private struct PublicKeyCredentialDescriptor: Decodable {
    let type: String
    let id: String
    let transports: [String]?
}

private struct AuthenticatorSelectionCriteria: Decodable {
    let authenticatorAttachment: String?
    let requireResidentKey: Bool?
    let residentKey: String?
    let userVerification: String?
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    func base64URLToBase64() -> String {
        var result = replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while result.count % 4 != 0 {
            result += "="
        }
        return result
    }
}

// Default presentation providers
#if os(iOS)
    private class DefaultIOSPresentationProvider: NSObject, ASAuthorizationControllerPresentationContextProviding {
        func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first
            else {
                fatalError("No window found in the current window scene")
            }
            return window
        }
    }

#elseif os(macOS)
    private class DefaultMacPresentationProvider: NSObject, ASAuthorizationControllerPresentationContextProviding {
        func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
            // Use key window to properly anchor passkey prompt when sheets are presented
            guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else {
                fatalError("No window found in the application")
            }
            return window
        }
    }
#else
    private class DefaultPresentationProvider: NSObject, ASAuthorizationControllerPresentationContextProviding {
        func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
            fatalError("Unsupported platform")
        }
    }
#endif

// MARK: - Supporting Types

// Message type identifiers
public enum ArkavoMessageType: UInt8 {
    case publicKey = 0x01
    case kasKey = 0x02
    case rewrap = 0x03
    case rewrappedKey = 0x04
    case natsMessage = 0x05
    case natsEvent = 0x06
}

// Protocol for messages
protocol ArkavoMessage {
    var messageType: ArkavoMessageType { get }
    func payload() -> Data
}

// Extension to handle common message formatting
extension ArkavoMessage {
    func toData() -> Data {
        var data = Data()
        data.append(messageType.rawValue)
        data.append(payload())
        return data
    }
}

// Concrete message implementations
struct PublicKeyMessage: ArkavoMessage {
    let messageType: ArkavoMessageType = .publicKey
    let publicKey: Data

    func payload() -> Data {
        publicKey
    }
}

struct KASKeyMessage: ArkavoMessage {
    let messageType: ArkavoMessageType = .kasKey

    func payload() -> Data {
        Data()
    }
}

struct RewrapMessage: ArkavoMessage {
    let messageType: ArkavoMessageType = .rewrap
    let header: Header

    func payload() -> Data {
        header.toData()
    }
}

struct RewrappedKeyMessage: ArkavoMessage {
    let messageType: ArkavoMessageType = .rewrappedKey
    let rewrappedKey: Data

    func payload() -> Data {
        rewrappedKey
    }
}

struct NATSMessage: ArkavoMessage {
    let messageType: ArkavoMessageType = .natsMessage
    let message: Data

    func payload() -> Data {
        message
    }
}

struct NATSEvent: ArkavoMessage {
    let messageType: ArkavoMessageType = .natsEvent
    let message: Data

    func payload() -> Data {
        message
    }
}

/// Supported elliptic curves for key exchange
public enum KeyExchangeCurve {
    case p256
    case p384
    case p521

    var keySize: Int {
        switch self {
        case .p256: 32
        case .p384: 48
        case .p521: 66
        }
    }

    var compressedKeySize: Int {
        // Compressed public key is 1 byte prefix + key size
        keySize + 1
    }
}

/// Protocol for curve-specific key operations
private protocol CurveKeyPair {
    var publicKeyData: Data { get }
    func computeSharedSecret(withPublicKeyData: Data) throws -> SharedSecret
}

// Concrete implementations for each curve
private struct P256KeyPair: CurveKeyPair {
    let privateKey: P256.KeyAgreement.PrivateKey

    var publicKeyData: Data {
        privateKey.publicKey.compressedRepresentation
    }

    func computeSharedSecret(withPublicKeyData data: Data) throws -> SharedSecret {
        let publicKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: data)
        return try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
    }
}

private struct P384KeyPair: CurveKeyPair {
    let privateKey: P384.KeyAgreement.PrivateKey

    var publicKeyData: Data {
        privateKey.publicKey.compressedRepresentation
    }

    func computeSharedSecret(withPublicKeyData data: Data) throws -> SharedSecret {
        let publicKey = try P384.KeyAgreement.PublicKey(compressedRepresentation: data)
        return try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
    }
}

private struct P521KeyPair: CurveKeyPair {
    let privateKey: P521.KeyAgreement.PrivateKey

    var publicKeyData: Data {
        privateKey.publicKey.compressedRepresentation
    }

    func computeSharedSecret(withPublicKeyData data: Data) throws -> SharedSecret {
        let publicKey = try P521.KeyAgreement.PublicKey(compressedRepresentation: data)
        return try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
    }
}

// WebAuthn Registration Delegate
private class WebAuthnRegistrationDelegate: NSObject, ASAuthorizationControllerDelegate {
    private let continuation: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialRegistration, Error>

    init(continuation: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialRegistration, Error>) {
        self.continuation = continuation
    }

    func authorizationController(controller _: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        print("✅ WebAuthnRegistrationDelegate: Authorization succeeded")
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            print("❌ WebAuthnRegistrationDelegate: Invalid credential type")
            continuation.resume(throwing: ArkavoError.authenticationFailed("Invalid credential type"))
            return
        }
        print("✅ WebAuthnRegistrationDelegate: Got valid credential, resuming continuation")
        continuation.resume(returning: credential)
    }

    func authorizationController(controller _: ASAuthorizationController, didCompleteWithError error: Error) {
        print("❌ WebAuthnRegistrationDelegate: Authorization failed with error")
        // Check for duplicate credential error (errSecDuplicateItem = -25300)
        let nsError = error as NSError
        print("❌ Error domain: '\(nsError.domain)'")
        print("❌ Error code: \(nsError.code)")
        print("❌ Error description: '\(error.localizedDescription)'")
        print("❌ Error userInfo: \(nsError.userInfo)")

        // The error will be caught and handled in registerUser, so just pass it through
        continuation.resume(throwing: error)
    }
}

private class WebAuthnAuthenticationDelegate: NSObject, ASAuthorizationControllerDelegate {
    private let continuation: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialAssertion, Error>

    init(continuation: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialAssertion, Error>) {
        self.continuation = continuation
    }

    func authorizationController(controller _: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        print("\n=== WebAuthn Authentication Completion ===")

        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            print("Error: Received invalid credential type")
            print("Actual type: \(type(of: authorization.credential))")
            continuation.resume(throwing: ArkavoError.authenticationFailed("Invalid credential type"))
            return
        }

        print("Successfully received credential:")
        print("Raw AuthenticatorData length: \(credential.rawAuthenticatorData.count) bytes")
        print("Signature length: \(credential.signature.count) bytes")
        print("UserID present: \(credential.userID != nil)")
        print("=== End WebAuthn Authentication Completion ===\n")

        continuation.resume(returning: credential)
    }

    func authorizationController(controller _: ASAuthorizationController, didCompleteWithError error: Error) {
        print("\n=== WebAuthn Authentication Error ===")
        print("Error: \(error)")
        if let authError = error as? ASAuthorizationError {
            print("ASAuthorization Error Code: \(authError.code.rawValue)")
            print("Error Domain: \(authError.errorCode)")
            switch authError.code {
            case .canceled:
                print("User cancelled the authorization")
            case .invalidResponse:
                print("The authorization request received an invalid response")
            case .notHandled:
                print("The authorization request wasn't handled")
            case .failed:
                print("The authorization request failed")
            case .notInteractive:
                print("The authorization request requires an interactive session")
            case .unknown:
                print("An unknown error occurred")
            case .matchedExcludedCredential:
                print("matched excluded credential")
            case .credentialImport:
                print("credential import")
            case .credentialExport:
                print("credential export")
            default:
                print("An unexpected error occurred")
            }
        }
        print("=== End WebAuthn Authentication Error ===\n")
        continuation.resume(throwing: error)
    }
}

// Response type for authentication options
struct AuthenticationOptionsResponse: Decodable {
    let publicKey: PublicKeyAuthenticationOptions
}

struct PublicKeyAuthenticationOptions: Decodable {
    let challenge: String
    let timeout: Int?
    let rpId: String?
    let allowCredentials: [AllowCredential]?
    let userVerification: String?

    /// The base64url ids of the listed `public-key` credentials (none when the server lists none).
    var publicKeyCredentialIDs: [String] {
        (allowCredentials ?? []).filter { $0.type == "public-key" }.map(\.id)
    }
}

struct AllowCredential: Decodable {
    let id: String
    let type: String
}

/// The fields of the passkey sheet's assertion that `POST /authenticate` carries.
struct PasskeyAssertion: Sendable, Equatable {
    let credentialID: Data
    let rawClientDataJSON: Data
    let rawAuthenticatorData: Data
    let signature: Data
    let userID: Data?
}

/// identity's reply to a passkey ceremony: the auth CWT and the account's handle.
struct AuthenticationReply: Equatable {
    let token: String
    let handle: String
}

public struct ArkavoProfile: Codable {
    public let handle: String
    public let did: String
    public let displayName: String
    public let avatarUrl: String
    public let description: String
    public let creationDate: String
    public let publicID: String
}

class ProfileCache {
    private let capacity: Int
    private var cache = [Data: ArkavoProfile]()
    private var usageOrder = [Data]()

    init(capacity: Int = 100) {
        self.capacity = capacity
    }

    func get(_ key: Data) -> ArkavoProfile? {
        guard let value = cache[key] else { return nil }

        // Move to most recently used
        if let index = usageOrder.firstIndex(of: key) {
            usageOrder.remove(at: index)
        }
        usageOrder.append(key)

        return value
    }

    func set(_ key: Data, value: ArkavoProfile) {
        // If key exists, update value and move to most recent
        if cache[key] != nil {
            if let index = usageOrder.firstIndex(of: key) {
                usageOrder.remove(at: index)
            }
        } else if cache.count >= capacity {
            // Remove least recently used item
            if let lru = usageOrder.first {
                cache.removeValue(forKey: lru)
                usageOrder.removeFirst()
            }
        }

        cache[key] = value
        usageOrder.append(key)
    }
}

