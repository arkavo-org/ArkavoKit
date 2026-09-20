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

    // MARK: - register-attest error discrimination
    //
    // Per authnz-rs docs/app-attest-preflight-contract.md, the client branches
    // on the stable `error` token and never on the status alone.
    // `attest_registration_cap` is the only permanent refusal: it tells a user
    // this device can never register again. Everything else — including the
    // 503 `app_id_not_configured` a fail-closed server returns for every user
    // at once — must stay retryable.

    func testOnlyTheLifetimeCapTokenIsPermanent() {
        XCTAssertTrue(ArkavoClient.isPermanentRefusal("attest_registration_cap"))
    }

    func testEveryOtherContractCodeIsRetryable() {
        for code in [
            "attest_rate_limited",
            "app_id_mismatch",
            "app_id_not_configured",
            "attestation_invalid",
            "session_invalid",
            "attest_unavailable",
        ] {
            XCTAssertFalse(
                ArkavoClient.isPermanentRefusal(code),
                "\(code) must not be treated as a permanent refusal"
            )
        }
    }

    func testUnknownAndMissingCodesStayRetryable() {
        XCTAssertFalse(ArkavoClient.isPermanentRefusal(nil), "a bodyless refusal must not become permanent")
        XCTAssertFalse(ArkavoClient.isPermanentRefusal(""))
        XCTAssertFalse(ArkavoClient.isPermanentRefusal("some_future_code"))
        XCTAssertFalse(
            ArkavoClient.isPermanentRefusal("ATTEST_REGISTRATION_CAP"),
            "the token is exact; a near-miss must not reach the permanent verdict"
        )
    }

    func testErrorTokenAndDescriptionAreReadFromTheContractEnvelope() {
        let body = Data(#"{"error":"attest_registration_cap","error_description":"lifetime cap reached"}"#.utf8)
        XCTAssertEqual(ArkavoClient.errorCode(from: body), "attest_registration_cap")
        XCTAssertEqual(ArkavoClient.errorDescription(from: body), "lifetime cap reached")
    }

    func testPlainTextBodiesYieldNoTokenSoNothingIsPermanent() {
        // Task 5 has not landed; DeviceCheckError still renders plain text.
        let body = Data("Forbidden".utf8)
        XCTAssertNil(ArkavoClient.errorCode(from: body))
        XCTAssertFalse(ArkavoClient.isPermanentRefusal(ArkavoClient.errorCode(from: body)))
    }
}
