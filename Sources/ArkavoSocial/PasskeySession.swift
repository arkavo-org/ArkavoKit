import CryptoKit
import Foundation
import Security

// Passkey session renewal (authnz-rs #108, contract `docs/session-renewal.md`
// at 9f932af). A sign-in opens a session bound to a Secure Enclave key; a
// renewal trades the session's single-use credential, signed by that key, for
// a fresh auth token and the next credential.

/// A token from `ArkavoClient.renewSession()`. It is a passkey auth CWT like a
/// sign-in's, with entitlements read again, plus `auth_time`: it never counts
/// as a recent passkey assertion (adding a passkey and account deletion still
/// need a sign-in).
public struct RenewedSession: Sendable, Equatable {
    public let token: String
    /// When `token` expires.
    public let expiresAt: Date
    /// When the session ends, whatever renews it: 24 h after the passkey sign-in that opened it.
    public let sessionExpiresAt: Date

    public init(token: String, expiresAt: Date, sessionExpiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
        self.sessionExpiresAt = sessionExpiresAt
    }
}

/// Why `renewSession()` returned no token. `.noSession` and `.sessionEnded`
/// mean a passkey sign-in.
public enum PasskeySessionError: Error, Sendable, Equatable {
    /// This app holds no session: none was opened, it ended, or its device key no longer loads.
    case noSession
    /// The session is over and forgotten on this device.
    case sessionEnded(SessionEndReason)
    /// identity failed (500 or 503). The session is unchanged; a later renewal sends the same credential.
    case serverFailure
}

/// Why a session ended. The first seven are identity's `reason`s.
public enum SessionEndReason: String, Sendable, Equatable {
    case notFound = "not_found"
    case invalidProof = "invalid_proof"
    case invalidCredential = "invalid_credential"
    case reused
    case idle
    case expired
    case accountDeleted = "account_deleted"
    /// The request was sent and its answer lost. The credential may have
    /// rotated, so presenting it again could end the session as reused.
    case responseLost = "response_lost"
    /// An answer the contract does not describe, or a `reason` this client does not know.
    case unexpectedResponse = "unexpected_response"
}

/// The identity server and the transport a session call uses.
struct PasskeySessionEndpoint: Sendable {
    let identity: URL
    let send: @MainActor @Sendable (URLRequest) async throws -> (Data, URLResponse)
}

/// The messages the device key signs: UTF-8, lines joined by `\n`, no trailing newline.
enum PasskeySessionMessage {
    static func open(sub: String, cti: Data, publicKey: String) -> String {
        "arkavo-session-open-v1\n\(sub)\n\(cti.base64URLEncodedString())\n\(publicKey)"
    }

    static func refresh(sessionId: String, credential: String) -> String {
        "arkavo-session-refresh-v1\n\(sessionId)\n\(credential)"
    }

    static func signout(sessionId: String) -> String {
        "arkavo-session-signout-v1\n\(sessionId)"
    }
}

// MARK: - Device key

/// A session's P-256 device key.
protocol SessionDeviceKey: Sendable {
    /// The 65-byte uncompressed X9.63 point, `04 || x || y`.
    var publicKey: Data { get }
    /// What the store keeps to load the key again.
    var persistentForm: Data { get }
    /// ECDSA P-256 over SHA-256 of `message`, as raw `r || s` (64 bytes), not DER.
    func signature(for message: Data) throws -> Data
}

@MainActor
protocol SessionKeyFactory {
    func make() throws -> any SessionDeviceKey
    func restore(_ persistentForm: Data) throws -> any SessionDeviceKey
}

/// A Secure Enclave key: the private key never leaves the enclave. Its
/// persistent form is a blob that only this device's enclave can use.
struct SecureEnclaveSessionKey: SessionDeviceKey {
    let key: SecureEnclave.P256.Signing.PrivateKey

    var publicKey: Data { key.publicKey.x963Representation }
    var persistentForm: Data { key.dataRepresentation }

    func signature(for message: Data) throws -> Data {
        // CryptoKit's raw representation is r || s; SecKeyCreateSignature's would be DER.
        try key.signature(for: message).rawRepresentation
    }
}

struct SecureEnclaveSessionKeys: SessionKeyFactory {
    func make() throws -> any SessionDeviceKey {
        // Usable only while the device is unlocked, and only on this device.
        SecureEnclaveSessionKey(key: try SecureEnclave.P256.Signing.PrivateKey())
    }

    func restore(_ persistentForm: Data) throws -> any SessionDeviceKey {
        SecureEnclaveSessionKey(key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: persistentForm))
    }
}

// MARK: - Store

/// What this app keeps of its session.
struct PasskeySessionRecord: Codable, Equatable, Sendable {
    /// Lowercase, as the server formats it in the messages it verifies.
    var sessionId: String
    var credential: String
    var deviceKey: Data
    /// The `sub` of the token that opened the session.
    var account: String
}

@MainActor
protocol PasskeySessionStore {
    func load() -> PasskeySessionRecord?
    func save(_ record: PasskeySessionRecord) throws
    func delete()
}

/// One keychain item in this app's own access group, on this device only.
///
/// No `kSecAttrAccessGroup` is set, so the item goes to the app's default group:
/// the first entry of its keychain-access-groups, which is the app's own in both
/// Arkavo apps (`…com.arkavo.Arkavo`, `…com.arkavo.ArkavoCreator`). Each app
/// keeps its own session: the credential rotates on every use, so two apps
/// sharing one would race each other into `reused`. An item that lands in a
/// shared group (`com.arkavo.webauthn`, `.did`, `.handle`) is removed and the
/// save fails.
struct KeychainPasskeySessionStore: PasskeySessionStore {
    static let service = "com.arkavo.passkey-session"
    static let account = "session"
    static let sharedGroups = ["com.arkavo.webauthn", "com.arkavo.did", "com.arkavo.handle"]

    enum StoreError: Error {
        case status(OSStatus)
        case sharedGroup
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func load() -> PasskeySessionRecord? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(PasskeySessionRecord.self, from: data)
    }

    func save(_ record: PasskeySessionRecord) throws {
        let data = try JSONEncoder().encode(record)
        let updated = SecItemUpdate(itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw StoreError.status(updated) }

        var add = itemQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        add[kSecReturnAttributes as String] = true
        var attributes: AnyObject?
        let added = SecItemAdd(add as CFDictionary, &attributes)
        guard added == errSecSuccess else { throw StoreError.status(added) }
        let group = (attributes as? [String: Any])?[kSecAttrAccessGroup as String] as? String ?? ""
        if Self.sharedGroups.contains(where: { group.hasSuffix(".\($0)") }) {
            delete()
            throw StoreError.sharedGroup
        }
    }

    func delete() {
        SecItemDelete(itemQuery as CFDictionary)
    }
}

// MARK: - Sessions

/// This app's passkey session. Opens, renewals, sign-outs and discards run one
/// at a time per process, and concurrent renewals share one request: two
/// renewals with one credential would end the session as reused.
///
/// Logs carry statuses and reasons only: never a token, credential, key,
/// signature or session id.
@MainActor
final class PasskeySessions {
    static let shared = PasskeySessions(store: KeychainPasskeySessionStore(), keys: SecureEnclaveSessionKeys())

    private let store: any PasskeySessionStore
    private let keys: any SessionKeyFactory
    /// The last operation queued; the next one starts after it.
    private var last: Task<Void, Never>?
    /// The renewal queued or running, which later callers share.
    private var renewal: Task<RenewedSession, Error>?

    /// Open and sign-out answers bound how long a sign-in or sign-out waits.
    private static let shortTimeout: TimeInterval = 15

    init(store: any PasskeySessionStore, keys: any SessionKeyFactory) {
        self.store = store
        self.keys = keys
    }

    /// Runs `operation` after every operation queued before it.
    private func serialized<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = last
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        last = Task { _ = await task.value }
        return await task.value
    }

    // MARK: Open

    /// Opens a session with `token`, a passkey auth CWT that `POST /authenticate`
    /// returned at most 300 s ago, replacing (and signing out) the session this
    /// app held. Never throws: false means no session, and the next expiry asks
    /// for the passkey.
    @discardableResult
    func open(token: String, via endpoint: PasskeySessionEndpoint) async -> Bool {
        await serialized { await self.performOpen(token: token, via: endpoint) }
    }

    private func performOpen(token: String, via endpoint: PasskeySessionEndpoint) async -> Bool {
        await performEnd(via: endpoint)
        guard let claims = CWTSubject.subjectAndID(fromToken: token) else {
            print("PasskeySessions.open: the token names no sub and cti; no session")
            return false
        }
        let key: any SessionDeviceKey
        let publicKey: String
        let proof: Data
        do {
            key = try keys.make()
            publicKey = key.publicKey.base64URLEncodedString()
            let message = PasskeySessionMessage.open(sub: claims.sub, cti: claims.cti, publicKey: publicKey)
            proof = try key.signature(for: Data(message.utf8))
        } catch {
            print("PasskeySessions.open: no Secure Enclave key; no session")
            return false
        }

        var request = Self.post("session", ["publicKey": publicKey, "proof": proof.base64URLEncodedString()], at: endpoint)
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        request.timeoutInterval = Self.shortTimeout
        guard let (data, status) = try? await Self.send(request, via: endpoint) else {
            print("PasskeySessions.open: no answer; no session")
            return false
        }
        guard status == 201,
              let opened = try? JSONDecoder().decode(OpenReply.self, from: data),
              let sessionId = UUID(uuidString: opened.sessionId)?.uuidString.lowercased()
        else {
            print("PasskeySessions.open: status=\(status); no session")
            return false
        }
        do {
            try store.save(PasskeySessionRecord(
                sessionId: sessionId,
                credential: opened.credential,
                deviceKey: key.persistentForm,
                account: claims.sub
            ))
        } catch {
            print("PasskeySessions.open: the session could not be kept: \(Self.describe(error))")
            return false
        }
        print("PasskeySessions.open: opened")
        return true
    }

    // MARK: Renew

    /// Trades the session's credential for a fresh token, and keeps the next
    /// credential before returning. Writes no token.
    ///
    /// - Throws: `PasskeySessionError`; or, with the session unchanged, the
    ///   `URLError` of a request that never left the device, or the device
    ///   key's signing error.
    func renew(via endpoint: PasskeySessionEndpoint) async throws -> RenewedSession {
        if let renewal { return try await renewal.value }
        let previous = last
        let task = Task { @MainActor in
            await previous?.value
            defer { self.renewal = nil }
            return try await self.performRenewal(via: endpoint)
        }
        renewal = task
        last = Task { _ = try? await task.value }
        return try await task.value
    }

    private func performRenewal(via endpoint: PasskeySessionEndpoint) async throws -> RenewedSession {
        guard var record = store.load() else { throw PasskeySessionError.noSession }
        guard let key = try? keys.restore(record.deviceKey) else {
            print("PasskeySessions.renew: the device key no longer loads; session forgotten")
            store.delete()
            throw PasskeySessionError.noSession
        }
        let message = PasskeySessionMessage.refresh(sessionId: record.sessionId, credential: record.credential)
        let signature = try key.signature(for: Data(message.utf8))
        let request = Self.post("session/refresh", [
            "sessionId": record.sessionId,
            "credential": record.credential,
            "signature": signature.base64URLEncodedString(),
        ], at: endpoint)

        let data: Data
        let status: Int
        do {
            (data, status) = try await Self.send(request, via: endpoint)
        } catch let error as URLError where Self.neverSent(error) {
            print("PasskeySessions.renew: not sent (\(error.code.rawValue)); session kept")
            throw error
        } catch {
            throw ended(.responseLost)
        }

        switch status {
        case 200:
            guard let reply = try? JSONDecoder().decode(RefreshReply.self, from: data) else {
                throw ended(.unexpectedResponse)
            }
            record.credential = reply.credential
            do {
                try store.save(record)
            } catch {
                // The old credential is spent: keep nothing that would present it again.
                print("PasskeySessions.renew: the next credential could not be kept: \(Self.describe(error)); session forgotten")
                store.delete()
            }
            print("PasskeySessions.renew: renewed")
            return RenewedSession(
                token: reply.token,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(reply.expiresAt)),
                sessionExpiresAt: Date(timeIntervalSince1970: TimeInterval(reply.sessionExpiresAt))
            )
        case 401:
            let refusal = try? JSONDecoder().decode(Refusal.self, from: data)
            guard refusal?.error == "session_ended", let wire = refusal?.reason else {
                throw ended(.unexpectedResponse)
            }
            throw ended(SessionEndReason(rawValue: wire).flatMap(Self.serverReason) ?? .unexpectedResponse)
        case 500, 503:
            print("PasskeySessions.renew: status=\(status); session kept")
            throw PasskeySessionError.serverFailure
        default:
            print("PasskeySessions.renew: status=\(status)")
            throw ended(.unexpectedResponse)
        }
    }

    /// Forgets the session and returns the error that says why.
    private func ended(_ reason: SessionEndReason) -> PasskeySessionError {
        print("PasskeySessions.renew: ended (\(reason.rawValue)); session forgotten")
        store.delete()
        return .sessionEnded(reason)
    }

    /// Only identity's own reasons; the client-side ones never come over the wire.
    private static func serverReason(_ reason: SessionEndReason) -> SessionEndReason? {
        switch reason {
        case .responseLost, .unexpectedResponse: nil
        default: reason
        }
    }

    /// Errors URLSession reports before any byte reaches the server.
    private static func neverSent(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
         .callIsActive, .appTransportSecurityRequiresSecureConnection].contains(error.code)
    }

    // MARK: End

    /// Signs the session out and forgets it here, whatever identity answers.
    func end(via endpoint: PasskeySessionEndpoint) async {
        await serialized { await self.performEnd(via: endpoint) }
    }

    private func performEnd(via endpoint: PasskeySessionEndpoint) async {
        guard let record = store.load() else { return }
        defer { store.delete() }
        guard let key = try? keys.restore(record.deviceKey),
              let signature = try? key.signature(for: Data(PasskeySessionMessage.signout(sessionId: record.sessionId).utf8))
        else {
            print("PasskeySessions.end: the device key no longer signs; session forgotten")
            return
        }
        var request = Self.post("session/signout", [
            "sessionId": record.sessionId,
            "signature": signature.base64URLEncodedString(),
        ], at: endpoint)
        request.timeoutInterval = Self.shortTimeout
        let status = try? await Self.send(request, via: endpoint).1
        print("PasskeySessions.end: status=\(status.map(String.init) ?? "none"); session forgotten")
    }

    /// Forgets `account`'s session without asking identity: its deletion ends the session there.
    func discard(account: UUID) async {
        await serialized {
            guard let record = self.store.load(), UUID(uuidString: record.account) == account else { return }
            self.store.delete()
        }
    }

    // MARK: Transport

    private static func post(_ path: String, _ body: [String: String], at endpoint: PasskeySessionEndpoint) -> URLRequest {
        var request = URLRequest(url: endpoint.identity.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The body and status; a non-HTTP answer counts as status 0.
    private static func send(_ request: URLRequest, via endpoint: PasskeySessionEndpoint) async throws -> (Data, Int) {
        let (data, response) = try await endpoint.send(request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// An error without any credential: its type and, for the keychain, its status.
    private static func describe(_ error: Error) -> String {
        if case let KeychainPasskeySessionStore.StoreError.status(status) = error { return "keychain status \(status)" }
        return String(describing: type(of: error))
    }

    private struct OpenReply: Decodable {
        let sessionId: String
        let credential: String
    }

    private struct RefreshReply: Decodable {
        let token: String
        let expiresAt: Int64
        let credential: String
        let sessionExpiresAt: Int64
    }

    private struct Refusal: Decodable {
        let error: String?
        let reason: String?
    }
}

// MARK: - ArkavoClient

public extension ArkavoClient {
    /// Renews this app's passkey session: a fresh auth token without the passkey.
    ///
    /// The sign-in (`connect`) opened the session. The next credential is kept
    /// before this returns; no token is written, so the app stores the token
    /// itself (only if the stored token is still the same account's).
    /// Renewals run one at a time per process; concurrent callers share one.
    ///
    /// Renew only while the person is using the app (frontmost with input in
    /// the last 15 min, or a recording, stream, publish or playback running):
    /// before `expiresAt`, and once on a 401 from a resource server. Never on a
    /// background timer, which would keep an idle session alive.
    ///
    /// - Throws: `PasskeySessionError.noSession` or `.sessionEnded`: sign in
    ///   with the passkey. `.serverFailure`: the session is unchanged, renew
    ///   later. A `URLError` for a request that never left the device, or the
    ///   device key's signing error: the session is unchanged.
    func renewSession() async throws -> RenewedSession {
        try await passkeySessions.renew(via: passkeySessionEndpoint)
    }

    /// Signs this app's passkey session out and forgets it on this device,
    /// whatever identity answers. Call it on sign-out and before deleting the
    /// account; `disconnect()` does not. The shared token is left as it is.
    func endSession() async {
        await passkeySessions.end(via: passkeySessionEndpoint)
    }
}
