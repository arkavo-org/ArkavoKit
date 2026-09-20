import CryptoKit
import os
import XCTest
@testable import ArkavoSocial

/// App Attest cannot run in the Simulator or under `swift test` — there is no
/// Secure Enclave attestation to perform. These tests cover what a stub can
/// actually prove: an unsupported device is refused rather than silently
/// let through, ordering (generateKey before attest, and neither called when
/// unsupported), and that the client-data hash sent to the server is exactly
/// SHA-256 of the server-issued challenge string.
final class AppAttestServiceTests: XCTestCase {
    struct StubAttester: AppAttesting {
        let isSupported: Bool
        func generateKey() async throws -> String { "stub-key-id" }
        func attest(keyID _: String, clientDataHash _: Data) async throws -> Data {
            Data("stub-attestation".utf8)
        }
    }

    /// Records calls instead of just stubbing a return value, so ordering
    /// (and short-circuiting on an unsupported device) can be asserted
    /// rather than assumed.
    final class RecordingAttester: AppAttesting, @unchecked Sendable {
        let isSupported: Bool
        private let state = OSAllocatedUnfairLock<(generateKeyCalls: Int, attestCalls: [(keyID: String, clientDataHash: Data)])>(
            initialState: (0, [])
        )

        init(isSupported: Bool) {
            self.isSupported = isSupported
        }

        var generateKeyCallCount: Int { state.withLock { $0.generateKeyCalls } }
        var attestCalls: [(keyID: String, clientDataHash: Data)] { state.withLock { $0.attestCalls } }

        func generateKey() async throws -> String {
            state.withLock { $0.generateKeyCalls += 1 }
            return "recorded-key-id"
        }

        func attest(keyID: String, clientDataHash: Data) async throws -> Data {
            state.withLock { $0.attestCalls.append((keyID: keyID, clientDataHash: clientDataHash)) }
            return Data("recorded-attestation".utf8)
        }
    }

    func testUnsupportedDeviceSurfacesADistinctError() async {
        let attester = StubAttester(isSupported: false)
        do {
            _ = try await AppAttestPreflight(attester: attester).keyAndAttestation(
                challenge: "c"
            )
            XCTFail("an unsupported device must not silently proceed")
        } catch AppAttestError.unsupportedDevice {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testClientDataHashIsSHA256OfTheChallenge() async throws {
        let attester = StubAttester(isSupported: true)
        let result = try await AppAttestPreflight(attester: attester)
            .keyAndAttestation(challenge: "fixture-challenge")
        XCTAssertEqual(
            result.clientDataHash,
            Data(SHA256.hash(data: Data("fixture-challenge".utf8)))
        )
    }

    func testKeyAndAttestationCarriesTheStubbedKeyAndAttestation() async throws {
        let attester = StubAttester(isSupported: true)
        let result = try await AppAttestPreflight(attester: attester)
            .keyAndAttestation(challenge: "fixture-challenge")
        XCTAssertEqual(result.keyID, "stub-key-id")
        XCTAssertEqual(result.attestation, Data("stub-attestation".utf8))
    }

    func testUnsupportedDeviceNeverTouchesTheAttester() async {
        let attester = RecordingAttester(isSupported: false)
        _ = try? await AppAttestPreflight(attester: attester).keyAndAttestation(challenge: "c")
        XCTAssertEqual(attester.generateKeyCallCount, 0, "an unsupported device must not generate a key")
        XCTAssertTrue(attester.attestCalls.isEmpty, "an unsupported device must not attest a key")
    }

    func testAttestIsCalledOnceWithTheGeneratedKeyAndTheChallengeHash() async throws {
        let attester = RecordingAttester(isSupported: true)
        let result = try await AppAttestPreflight(attester: attester)
            .keyAndAttestation(challenge: "fixture-challenge")

        XCTAssertEqual(attester.generateKeyCallCount, 1, "generateKey should run exactly once per preflight")
        XCTAssertEqual(attester.attestCalls.count, 1, "attest should run exactly once per preflight")
        XCTAssertEqual(attester.attestCalls[0].keyID, "recorded-key-id", "attest must use the key generateKey produced, not a fresh one")
        XCTAssertEqual(
            attester.attestCalls[0].clientDataHash,
            Data(SHA256.hash(data: Data("fixture-challenge".utf8)))
        )
        XCTAssertEqual(result.keyID, "recorded-key-id")
    }

    // MARK: - register-attest 403 discrimination
    //
    // A 403 carries two very different meanings and only one of them is
    // permanent. `registrationCapExceeded` tells a user this device can
    // never register again, so it must not be inferred from the status
    // code alone — a generic forbidden, or the server failing closed on an
    // unset APP_ATTEST_APP_ID, would be reported as a permanent refusal.

    func testLifetimeCapIsRecognizedFromTheErrorBody() {
        XCTAssertTrue(ArkavoClient.isLifetimeCapRefusal("lifetime_cap"))
        XCTAssertTrue(ArkavoClient.isLifetimeCapRefusal("AttestLifetimeCapExceeded"))
        XCTAssertTrue(ArkavoClient.isLifetimeCapRefusal("device lifetime registration cap reached"))
    }

    func testOtherForbiddenReasonsAreNotTreatedAsPermanent() {
        XCTAssertFalse(ArkavoClient.isLifetimeCapRefusal(nil), "a bodyless 403 must not become a permanent refusal")
        XCTAssertFalse(ArkavoClient.isLifetimeCapRefusal(""))
        XCTAssertFalse(ArkavoClient.isLifetimeCapRefusal("forbidden"))
        XCTAssertFalse(
            ArkavoClient.isLifetimeCapRefusal("APP_ATTEST_APP_ID is not configured"),
            "a server misconfiguration must stay retryable, not tell the user their device is barred forever"
        )
    }

    func testErrorMessageIsExtractedFromTheServerEnvelope() {
        let body = Data(#"{"error":"lifetime_cap"}"#.utf8)
        XCTAssertEqual(ArkavoClient.errorMessage(from: body), "lifetime_cap")
    }

    func testErrorMessageIsNilForBodiesThatAreNotTheErrorEnvelope() {
        XCTAssertNil(ArkavoClient.errorMessage(from: Data("not json".utf8)))
        XCTAssertNil(ArkavoClient.errorMessage(from: Data(#"{"detail":"nope"}"#.utf8)))
        XCTAssertNil(ArkavoClient.errorMessage(from: Data()))
    }
}
