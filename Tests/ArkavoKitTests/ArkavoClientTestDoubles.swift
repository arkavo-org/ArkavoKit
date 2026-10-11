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
