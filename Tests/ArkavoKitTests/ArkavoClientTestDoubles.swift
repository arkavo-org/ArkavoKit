import AuthenticationServices
import Foundation
@testable import ArkavoSocial

/// In-memory `AccountCredentialStore` that records every removal.
@MainActor
final class FakeCredentialStore: AccountCredentialStore {
    var token: String?
    var handle: String?
    var didKeyDeletionError: Error?
    private(set) var removals: [String] = []

    init(token: String? = nil, handle: String? = nil) {
        self.token = token
        self.handle = handle
    }

    func authenticationToken() -> String? { token }
    func sharedHandle() -> String? { handle }

    func deleteAuthenticationToken() {
        removals.append("token")
        token = nil
    }

    func deleteSharedHandleAndDID() {
        removals.append("sharedHandleAndDID")
        handle = nil
    }

    func deleteIdentityPair() { removals.append("identityPair") }

    func deleteDIDKey() throws {
        removals.append("didKey")
        if let didKeyDeletionError { throw didKeyDeletionError }
    }

    func deleteAppleAccount() { removals.append("appleAccount") }
}

/// Replays scripted HTTP outcomes in order and records each request.
@MainActor
final class ScriptedHTTP {
    enum Outcome {
        case status(Int, String)
        case failure(Error)
    }

    private var outcomes: [Outcome]
    private(set) var requests: [URLRequest] = []

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !outcomes.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        switch outcomes.removeFirst() {
        case let .status(code, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        case let .failure(error):
            throw error
        }
    }
}

/// Stands in for the system passkey sheet: records each assertion request and
/// answers with the scripted assertion or error.
@MainActor
final class ScriptedAssertion {
    private let outcome: Result<PasskeyAssertion, Error>
    private(set) var requests: [ASAuthorizationPlatformPublicKeyCredentialAssertionRequest] = []

    init(_ outcome: Result<PasskeyAssertion, Error>) {
        self.outcome = outcome
    }

    func perform(_ request: ASAuthorizationPlatformPublicKeyCredentialAssertionRequest) async throws -> PasskeyAssertion {
        requests.append(request)
        return try outcome.get()
    }
}

/// Records every passkey report instead of telling the system.
@MainActor
final class RecordingReporter: PasskeyCredentialReporting {
    struct Unknown: Equatable {
        let relyingPartyID: String
        let credentialID: Data
    }

    struct NoAcceptedCredentials: Equatable {
        let relyingPartyID: String
        let userHandle: Data
    }

    private(set) var unknown: [Unknown] = []
    private(set) var noAcceptedCredentials: [NoAcceptedCredentials] = []

    func reportUnknown(relyingPartyID: String, credentialID: Data) async {
        unknown.append(Unknown(relyingPartyID: relyingPartyID, credentialID: credentialID))
    }

    func reportNoAcceptedCredentials(relyingPartyID: String, userHandle: Data) async {
        noAcceptedCredentials.append(NoAcceptedCredentials(relyingPartyID: relyingPartyID, userHandle: userHandle))
    }
}

@MainActor
func makeTestClient() -> ArkavoClient {
    let client = ArkavoClient(
        authURL: URL(string: "https://identity.example.test")!,
        websocketURL: URL(string: "wss://kas.example.test")!,
        relyingPartyID: "identity.example.test"
    )
    // Never the device keychain or Secure Enclave.
    client.passkeySessions = PasskeySessions(store: InMemorySessionStore(), keys: SoftwareSessionKeys())
    return client
}

/// Holds an async call until the test opens it, so a test can act while a
/// deletion is suspended inside its passkey ceremony.
@MainActor
final class Gate {
    private var held: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private(set) var isHolding = false

    /// Called by the code under test; returns once `open()` is called.
    func pass() async {
        await withCheckedContinuation { continuation in
            held = continuation
            isHolding = true
            arrival?.resume()
            arrival = nil
        }
    }

    /// Called by the test; returns once something is waiting in `pass()`.
    func waitUntilHolding() async {
        if isHolding { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func open() {
        isHolding = false
        held?.resume()
        held = nil
    }
}

/// A client wired to a fake keychain, scripted ceremonies, scripted HTTP and a
/// recording passkey reporter.
///
/// The keychain starts signed in as "alice": the stored token's `sub` is
/// `account`, so a deletion of "alice" re-authenticates `account`.
@MainActor
final class DeletionHarness {
    /// The stored account's id, as identity mints it into the token's `sub` (lowercased).
    static let account = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
    /// An account other than `account`.
    static let otherAccount = UUID(uuidString: "9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")!

    /// A session token of `account`'s, as identity mints one.
    static func token(of account: UUID) -> String {
        TestCWT.token(sub: account.uuidString.lowercased())
    }

    /// `account`'s user handle: the UUID's 16 bytes.
    static func userHandle(of account: UUID) -> Data {
        withUnsafeBytes(of: account.uuid) { Data($0) }
    }

    let client = makeTestClient()
    let store = FakeCredentialStore(token: DeletionHarness.token(of: DeletionHarness.account), handle: "alice")
    let reporter = RecordingReporter()
    /// The account of every ceremony run, in order.
    private(set) var ceremonies: [UUID] = []

    init() {
        client.credentialStore = store
        client.credentialReporter = reporter
        // No test presents the real passkey sheet.
        client.assertionProvider = { _ in throw ASAuthorizationError(.failed) }
    }

    /// Each ceremony answers with the next token, for the account "alice", or
    /// throws the next error.
    func stubCeremonies(_ outcomes: [Result<String, Error>]) {
        stubReplies(outcomes.map { $0.map { AuthenticationReply(token: $0, handle: "alice") } })
    }

    /// Each ceremony returns the next reply or throws the next error.
    func stubReplies(_ outcomes: [Result<AuthenticationReply, Error>]) {
        var remaining = outcomes
        client.authenticator = { [unowned self] account in
            ceremonies.append(account)
            guard !remaining.isEmpty else { throw ArkavoError.invalidResponse }
            return try remaining.removeFirst().get()
        }
    }

    @discardableResult
    func stubHTTP(_ outcomes: [ScriptedHTTP.Outcome]) -> ScriptedHTTP {
        let http = ScriptedHTTP(outcomes)
        client.httpData = http.perform
        return http
    }
}
