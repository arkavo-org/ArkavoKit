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

@MainActor
func makeTestClient() -> ArkavoClient {
    ArkavoClient(
        authURL: URL(string: "https://identity.example.test")!,
        websocketURL: URL(string: "wss://kas.example.test")!,
        relyingPartyID: "identity.example.test"
    )
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

/// A client wired to a fake keychain, scripted ceremonies and scripted HTTP.
@MainActor
final class DeletionHarness {
    let client = makeTestClient()
    let store = FakeCredentialStore()
    /// The account name of every ceremony run, in order.
    private(set) var ceremonies: [String] = []

    init() {
        client.credentialStore = store
    }

    /// Each ceremony returns the next token or throws the next error.
    func stubCeremonies(_ outcomes: [Result<String, Error>]) {
        var remaining = outcomes
        client.authenticator = { [unowned self] accountName in
            ceremonies.append(accountName)
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
