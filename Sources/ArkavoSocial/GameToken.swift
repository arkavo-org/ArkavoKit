import CryptoKit
import Foundation

// The game-server token (authnz-rs #151, contract `docs/game-token.md` at
// 699d1c2). identity mints a short token for one game server, bound to the
// passkey session's device key; the game server refuses it without a proof
// signed by that key for each request. Minting is authenticated by the
// session, not by an auth token, and it never ends or renews the session.

/// A token for one game server, from `ArkavoClient.gameToken(audience:)`.
///
/// It is not a bearer token: every request to the game server also carries a
/// proof from `gameRequestProof(for:method:url:body:)`.
public struct GameToken: Sendable, Equatable {
    /// The token's text, sent to the game server exactly as it is.
    public let token: String
    /// The game server it is for.
    public let audience: String
    /// When it expires, by this device's clock (identity's time, corrected by the offset between the two):
    /// 15 minutes after the mint by default, and never after the session's deadline.
    public let expiresAt: Date
    /// Whether the account holds the Game Pass, as identity saw it at the mint. The game server decides
    /// from the token itself; this is for the app's own screens.
    public let onlinePlay: Bool
    /// Set when the mint renewed the passkey session on the way. Its auth token is not stored: the app
    /// stores it as it does `renewSession()`'s.
    public let renewedSession: RenewedSession?

    public init(token: String, audience: String, expiresAt: Date, onlinePlay: Bool, renewedSession: RenewedSession? = nil) {
        self.token = token
        self.audience = audience
        self.expiresAt = expiresAt
        self.onlinePlay = onlinePlay
        self.renewedSession = renewedSession
    }
}

/// What one request to the game server carries beside its token. The header names are the game server's.
public struct GameRequestProof: Sendable, Equatable {
    /// The token the proof was made for.
    public let token: String
    /// `t`: unix seconds on identity's clock, as the signed line carries it.
    public let timestamp: Int64
    /// The device key's raw `r‖s` signature, base64url without padding.
    public let signature: String

    public init(token: String, timestamp: Int64, signature: String) {
        self.token = token
        self.timestamp = timestamp
        self.signature = signature
    }
}

/// Why there is no game token or proof. Only `.sessionEnded` means the session is gone, and then it was
/// the renewal that ended it, never the mint.
public enum GameTokenError: Error, Sendable, Equatable {
    /// This app holds no passkey session: sign in with the passkey.
    case noSession
    /// The session is over: sign in with the passkey.
    case sessionEnded(SessionEndReason)
    /// identity refused the mint although the session renewed. The session is kept.
    case unauthorized
    /// identity does not mint for this audience.
    case invalidAudience
    /// identity refused the time twice, the second after correcting this device's clock by identity's.
    case clockRejected
    /// More than identity allows in a minute: mint again after `retryAfter` seconds.
    case rateLimited(retryAfter: TimeInterval)
    /// identity has no game tokens configured (503).
    case unavailable
    /// identity failed (500), or the renewal a 401 asked for did. The session is unchanged.
    case serverFailure
    /// An answer the contract does not describe. The session is unchanged.
    case unexpectedResponse(status: Int)
    /// The audience, method or URL cannot be signed: one is empty or would break a line.
    case invalidRequest
}

/// The game-token calls, so an app can put a fake behind them. `ArkavoClient` is the real one.
@MainActor
public protocol GameTokenProviding: Sendable {
    func gameToken(audience: String) async throws -> GameToken
    func gameRequestProof(for token: GameToken, method: String, url: URL, body: Data?) async throws -> GameRequestProof
}

// The conformance itself is declared in ArkavoClient.swift: `GameTokenProviding` is Sendable, and a
// Sendable conformance must be stated in the class's own file.
extension ArkavoClient {
    /// Mints a token for the game server `audience` (for example `https://game.arkavo.net`).
    ///
    /// Call it when the app is about to call the game server and holds no token, or one that expires
    /// within a minute; after the game server refuses an expired token; and after a purchase, every
    /// 20 s for about a minute and a half until `onlinePlay` is true. Only while the person is playing,
    /// never on a background timer. A mint can be repeated: a lost mint answer costs nothing.
    ///
    /// The mint does not keep the session alive, so this renews the session first when it has not been
    /// renewed for half its idle limit, and once more when identity answers 401. A renewal's auth token
    /// comes back in `renewedSession`; when the mint throws after a renewal that token is not returned,
    /// and `renewSession()` gives another when one is needed.
    ///
    /// The early renewal never costs the session by itself. When its answer is lost the session is kept
    /// and goes on signing, but its credential is spent: it is not presented again, so the session ends
    /// (`.sessionEnded(.responseLost)`) when identity next answers a mint with 401, or at the app's next
    /// `renewSession()`. The renewal a 401 asks for keeps the renewal's rule: a lost answer ends the session.
    ///
    /// No token is kept here. Near the session's deadline a new token can expire in under a minute: do
    /// not mint again when the token just received expires no later than the one before it.
    ///
    /// - Throws: `GameTokenError`; or, with the session unchanged, the `URLError` of a request that got
    ///   no answer, or the device key's signing error.
    public func gameToken(audience: String) async throws -> GameToken {
        try await passkeySessions.gameToken(audience: audience, via: passkeySessionEndpoint)
    }

    /// Signs one request to the game server with the session's device key.
    ///
    /// `url` is the absolute URL the request is sent to: its path and query are signed as they go on the
    /// wire. `method` is signed in uppercase, so set the request's `httpMethod` in uppercase too:
    /// URLSession sends a method such as `patch` as it is written. `body` is the request's body bytes,
    /// nil for none. The proof is good for 60 seconds, for this
    /// method, target, body and token only. For a long-lived connection, sign its handshake.
    ///
    /// The key signs only while the device is unlocked. There is no call that signs other bytes with it.
    ///
    /// - Throws: `GameTokenError.noSession` or `.invalidRequest`, or the device key's signing error.
    public func gameRequestProof(for token: GameToken, method: String, url: URL, body: Data?) async throws -> GameRequestProof {
        try await passkeySessions.gameRequestProof(for: token, method: method, url: url, body: body)
    }
}

/// The messages the device key signs for a game server: UTF-8, lines joined by `\n`, no trailing newline.
enum GameTokenMessage {
    static func mint(sessionId: String, audience: String, issuedAt: Int64) -> String {
        "arkavo-game-token-v1\n\(sessionId)\n\(audience)\n\(issuedAt)"
    }

    static func request(audience: String, method: String, target: String, t: Int64, body: Data, token: String) -> String {
        "arkavo-game-request-v1\n\(audience)\n\(method)\n\(target)\n\(t)\n\(hash(body))\n\(hash(Data(token.utf8)))"
    }

    /// The request target as sent: the percent-encoded path (`/` when empty), and `?` with the query when there is one.
    static func target(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?\(query)" }
        return target
    }

    /// Not empty, and no line break that would add a line to a signed message.
    static func isOneLine(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    private static func hash(_ bytes: Data) -> String {
        Data(SHA256.hash(data: bytes)).base64URLEncodedString()
    }
}

extension PasskeySessions {
    /// The idle limit assumed for a session whose open did not state one (identity's 66 minutes).
    private static let defaultIdleTimeout: TimeInterval = 3960
    /// The largest clock difference believed, in seconds (a hundred years).
    private static let maxClockOffset: UInt64 = 100 * 365 * 86400

    /// One answer to a mint that the caller acts on; every other answer is thrown.
    private enum MintAnswer {
        case minted(token: String, expiresAt: Date, onlinePlay: Bool)
        case clockCorrected
        case unauthorized
    }

    private struct MintReply: Decodable {
        let token: String?
        let expiresAt: Int64?
        let onlinePlay: Bool?
        let serverTime: Int64?
        let error: String?
    }

    /// Mints a game token for `audience`. Logs carry statuses only: never a token, signature or session id.
    func gameToken(audience: String, via endpoint: PasskeySessionEndpoint) async throws -> GameToken {
        guard GameTokenMessage.isOneLine(audience) else { throw GameTokenError.invalidRequest }
        // A sign-in in flight has forgotten the old session and not yet kept the new one.
        await settled()
        guard let record = store.load() else { throw GameTokenError.noSession }

        var renewed: RenewedSession?
        if isDueForRenewal(record) {
            do {
                // Nothing asked for this renewal yet, so an answer that cannot be read must not cost the
                // session: it is kept, with its credential spent, and the mint goes on.
                renewed = try await renew(via: endpoint, keepingSessionOnUnreadAnswer: true)
            } catch let error as PasskeySessionError {
                // identity failing leaves the session as it was: the mint may still succeed.
                if error != .serverFailure { throw Self.gameTokenError(error) }
            } catch {
                // Not sent, not signed, or answered unreadably: the session is kept and the mint goes on.
            }
        }

        var clockCorrected = false
        while true {
            switch try await requestGameToken(audience: audience, via: endpoint) {
            case let .minted(token, expiresAt, onlinePlay):
                return GameToken(token: token, audience: audience, expiresAt: expiresAt, onlinePlay: onlinePlay,
                                 renewedSession: renewed)
            case .clockCorrected:
                guard !clockCorrected else { throw GameTokenError.clockRejected }
                clockCorrected = true
            case .unauthorized:
                // The 401 does not say why. A renewal does, and only it may end the session.
                guard renewed == nil else { throw GameTokenError.unauthorized }
                do {
                    renewed = try await renew(via: endpoint)
                } catch let error as PasskeySessionError {
                    throw Self.gameTokenError(error)
                }
            }
        }
    }

    /// Signs the proof for one request to the game server.
    func gameRequestProof(for token: GameToken, method: String, url: URL, body: Data?) async throws -> GameRequestProof {
        guard GameTokenMessage.isOneLine(token.audience),
              !method.isEmpty, method.allSatisfy({ $0.isASCII && $0.isLetter }),
              let target = GameTokenMessage.target(of: url), target.hasPrefix("/"), GameTokenMessage.isOneLine(target)
        else { throw GameTokenError.invalidRequest }
        let method = method.uppercased()
        await settled()
        guard let record = store.load(), let key = try? keys.restore(record.deviceKey) else {
            throw GameTokenError.noSession
        }
        let t = identityTime()
        let message = GameTokenMessage.request(
            audience: token.audience, method: method, target: target, t: t, body: body ?? Data(), token: token.token
        )
        let signature = try await Self.signature(for: message, by: key)
        return GameRequestProof(token: token.token, timestamp: t, signature: signature.base64URLEncodedString())
    }

    /// Whether the session has gone unused for half its idle limit. A record that does not say when it
    /// was last renewed (kept by an earlier release) is not renewed early.
    private func isDueForRenewal(_ record: PasskeySessionRecord) -> Bool {
        // A spent credential is never presented: renewing would only end the session.
        guard record.credentialSpent != true, let renewedAt = record.renewedAt else { return false }
        let stated = record.idleTimeoutSeconds.map(TimeInterval.init) ?? Self.defaultIdleTimeout
        let idleTimeout = stated > 0 ? stated : Self.defaultIdleTimeout
        return now().timeIntervalSince(renewedAt) >= idleTimeout / 2
    }

    private func requestGameToken(audience: String, via endpoint: PasskeySessionEndpoint) async throws -> MintAnswer {
        guard let record = store.load(), let key = try? keys.restore(record.deviceKey) else {
            throw GameTokenError.noSession
        }
        let issuedAt = identityTime()
        let message = GameTokenMessage.mint(sessionId: record.sessionId, audience: audience, issuedAt: issuedAt)
        let signature = try await Self.signature(for: message, by: key)

        var request = URLRequest(url: endpoint.identity.appendingPathComponent("game/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "sessionId": record.sessionId,
            "audience": audience,
            "issuedAt": issuedAt,
            "signature": signature.base64URLEncodedString(),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        // A request that gets no answer changed nothing at identity: the transport's error goes to the caller.
        let (data, response) = try await endpoint.send(request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let reply = try? JSONDecoder().decode(MintReply.self, from: data)
        print("PasskeySessions.gameToken: status=\(status)")

        switch status {
        case 200:
            guard let token = reply?.token, let expiresAt = reply?.expiresAt, let onlinePlay = reply?.onlinePlay else {
                throw GameTokenError.unexpectedResponse(status: status)
            }
            if let serverTime = reply?.serverTime { keepIdentityClock(serverTime) }
            // identity's `expiresAt` is on its own clock; the app compares the expiry with this device's.
            let expiry = Date(timeIntervalSince1970: TimeInterval(expiresAt) - TimeInterval(identityClockOffset))
            return .minted(token: token, expiresAt: expiry, onlinePlay: onlinePlay)
        case 400:
            switch reply?.error {
            case "invalid_issued_at":
                guard let serverTime = reply?.serverTime else { throw GameTokenError.clockRejected }
                keepIdentityClock(serverTime)
                return .clockCorrected
            case "invalid_audience":
                throw GameTokenError.invalidAudience
            default:
                throw GameTokenError.unexpectedResponse(status: status)
            }
        case 401:
            return .unauthorized
        case 429:
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
            throw GameTokenError.rateLimited(retryAfter: max(0, retryAfter))
        case 500:
            throw GameTokenError.serverFailure
        case 503:
            throw GameTokenError.unavailable
        default:
            throw GameTokenError.unexpectedResponse(status: status)
        }
    }

    /// This device's clock in unix seconds, corrected by the last time identity told.
    private func identityTime() -> Int64 {
        deviceTime() + identityClockOffset
    }

    private func deviceTime() -> Int64 {
        Int64(now().timeIntervalSince1970.rounded(.down))
    }

    /// Keeps the offset to identity's clock. A time further from this device's than any real clock error
    /// is not believed, so no number identity sends can overflow the arithmetic here.
    private func keepIdentityClock(_ serverTime: Int64) {
        let (offset, overflow) = serverTime.subtractingReportingOverflow(deviceTime())
        guard !overflow, offset.magnitude <= Self.maxClockOffset else { return }
        identityClockOffset = offset
    }

    private static func gameTokenError(_ error: PasskeySessionError) -> GameTokenError {
        switch error {
        case .noSession: .noSession
        case let .sessionEnded(reason): .sessionEnded(reason)
        case .serverFailure: .serverFailure
        }
    }

    /// The device key's signature over `message`, made off the main actor: a Secure Enclave signature
    /// takes long enough to drop a frame.
    private nonisolated static func signature(for message: String, by key: any SessionDeviceKey) async throws -> Data {
        try await Task.detached { try key.signature(for: Data(message.utf8)) }.value
    }
}
