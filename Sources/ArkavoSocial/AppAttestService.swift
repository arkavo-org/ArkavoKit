import CryptoKit
import DeviceCheck
import Foundation

/// Errors from the App Attest registration preflight.
///
/// `rateLimited` and `registrationCapExceeded` are both refusals from
/// `device-check/register-attest`, but they are kept as distinct cases
/// rather than one "try again later" bucket: a rate limit is temporary
/// (the rolling window resets, so it carries a `retryAfter`) while a
/// registration-cap refusal is the device's *lifetime* budget being
/// spent — no wait makes that succeed, so the case carries no interval
/// at all. That asymmetry in the type is deliberate: it stops a caller
/// from writing a retry loop around a refusal that can never clear.
public enum AppAttestError: Error, Sendable {
    /// No Secure Enclave. Registration targets Apple silicon and iOS 26+, so
    /// this should be unreachable in production — surfaced distinctly rather
    /// than folded into a generic failure so it is visible if it ever is not.
    case unsupportedDevice
    /// The server rejected the attestation itself (malformed, bad nonce,
    /// chain didn't verify, etc.) with a reason worth surfacing.
    case attestationRejected(String)
    /// HTTP 429: this device's registration budget for the current rolling
    /// window is spent. Temporary — retry after the given interval.
    case rateLimited(retryAfter: TimeInterval)
    /// HTTP 403 from register-attest: this device hit its lifetime
    /// registration cap. Permanent — retrying can never succeed.
    case registrationCapExceeded
}

/// Abstraction over `DCAppAttestService` so the preflight logic (ordering,
/// hashing) can be tested without real Secure Enclave attestation, which
/// cannot run in the Simulator or under `swift test`.
public protocol AppAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attest(keyID: String, clientDataHash: Data) async throws -> Data
}

/// Live implementation backed by the real Secure Enclave / App Attest
/// service. Targets iOS 26+ and Apple silicon macOS only — there is
/// deliberately no non-Secure-Enclave fallback path; `isSupported` gates it.
public struct LiveAppAttester: AppAttesting {
    public init() {}

    public var isSupported: Bool { DCAppAttestService.shared.isSupported }

    public func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    public func attest(keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }
}

/// Runs the client half of the App Attest registration gate: generate a
/// key, hash the server-issued challenge, and attest that key against the
/// hash. The result is handed to `ArkavoClient` to POST to
/// `device-check/register-attest`.
public struct AppAttestPreflight: Sendable {
    public struct Result: Sendable {
        public let keyID: String
        public let attestation: Data
        public let clientDataHash: Data
    }

    private let attester: AppAttesting

    public init(attester: AppAttesting = LiveAppAttester()) {
        self.attester = attester
    }

    public func keyAndAttestation(challenge: String) async throws -> Result {
        guard attester.isSupported else { throw AppAttestError.unsupportedDevice }
        // The server verifies clientDataHash == SHA-256(challenge) — hash it
        // client-side the same way so the attestation binds to this exact
        // challenge and can't be replayed against a different one.
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let keyID = try await attester.generateKey()
        let attestation = try await attester.attest(keyID: keyID, clientDataHash: clientDataHash)
        return Result(keyID: keyID, attestation: attestation, clientDataHash: clientDataHash)
    }
}
