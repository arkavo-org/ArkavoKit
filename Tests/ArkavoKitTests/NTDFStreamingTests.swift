import XCTest
import Foundation
import CoreMedia
import Network
import os
import OpenTDFKit
@testable import ArkavoStreaming
@testable import ArkavoMedia

/// Integration tests for NTDF-RTMP streaming
/// Tests against production server at platform.arkavo.net
final class NTDFStreamingTests: XCTestCase {

    // MARK: - Test Configuration

    let kasURL = URL(string: "https://platform.arkavo.net")!
    let rtmpURL = "rtmp://localhost:1935"
    let testStreamKey = "live/test-ntdf-\(UUID().uuidString.prefix(8))"

    /// Skips the current test unless something accepts TCP connections at `rtmpURL`.
    ///
    /// The full-flow test needs a real RTMP server to talk to. Without one,
    /// `RTMPPublisher.connect` now fails with `connectionTimedOut` after its
    /// connect timeout rather than hanging, but that is still a failure, not a
    /// meaningful result, so probe first and skip cleanly.
    private func skipUnlessRTMPServerIsListening() throws {
        guard let url = URL(string: rtmpURL), let host = url.host, let port = url.port,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            XCTFail("Malformed rtmpURL: \(rtmpURL)")
            return
        }
        guard Self.isTCPListening(host: host, port: nwPort, timeout: 2) else {
            throw XCTSkip("no RTMP server on \(host):\(port)")
        }
    }

    /// Bounded TCP reachability probe: true only if the connection reaches `.ready`
    /// within `timeout`. Refused, unreachable, or timed-out all yield false.
    private static func isTCPListening(host: String, port: NWEndpoint.Port, timeout: TimeInterval) -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let settled = DispatchSemaphore(value: 0)
        let reachable = OSAllocatedUnfairLock(initialState: false)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                reachable.withLock { $0 = true }
                settled.signal()
            case .failed, .waiting, .cancelled:
                settled.signal()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        _ = settled.wait(timeout: .now() + timeout)
        connection.cancel()
        return reachable.withLock { $0 }
    }

    // MARK: - KAS Public Key Tests

    func testKASPublicKeyFetch() async throws {
        let kasService = KASPublicKeyService(kasURL: kasURL)
        let publicKey = try await kasService.fetchPublicKey()

        // Verify compressed P-256 key (33 bytes)
        XCTAssertEqual(publicKey.count, 33, "Expected 33-byte compressed P-256 key")

        // Verify it starts with 0x02 or 0x03 (compressed point prefix)
        let prefix = publicKey[0]
        XCTAssert(prefix == 0x02 || prefix == 0x03,
                  "Expected compressed point prefix (0x02 or 0x03), got 0x\(String(format: "%02x", prefix))")

        print("✅ KAS public key: \(publicKey.map { String(format: "%02x", $0) }.joined())")
    }

    func testKASMetadataCreation() async throws {
        let kasService = KASPublicKeyService(kasURL: kasURL)
        let kasMetadata = try await kasService.createKasMetadata()

        // Verify we can get the public key back
        let publicKey = try kasMetadata.getPublicKey()
        XCTAssertEqual(publicKey.count, 33, "Expected 33-byte compressed P-256 key")

        print("✅ KasMetadata created successfully")
    }

    // MARK: - NanoTDF Collection Tests

    func testCollectionCreation() async throws {
        let kasService = KASPublicKeyService(kasURL: kasURL)
        let kasMetadata = try await kasService.createKasMetadata()

        // Build collection
        let collection = try await NanoTDFCollectionBuilder()
            .kasMetadata(kasMetadata)
            .policy(.embeddedPlaintext(Data()))
            .configuration(.default)
            .build()

        let headerBytes = await collection.getHeaderBytes()
        XCTAssertGreaterThan(headerBytes.count, 0, "Header bytes should not be empty")

        print("✅ NanoTDF Collection created, header: \(headerBytes.count) bytes")
    }

    func testCollectionEncryption() async throws {
        let kasService = KASPublicKeyService(kasURL: kasURL)
        let kasMetadata = try await kasService.createKasMetadata()

        let collection = try await NanoTDFCollectionBuilder()
            .kasMetadata(kasMetadata)
            .policy(.embeddedPlaintext(Data()))
            .configuration(.default)
            .build()

        // Encrypt test data
        let testData = "Hello NTDF-RTMP!".data(using: .utf8)!
        let item = try await collection.encryptItem(plaintext: testData)
        let serialized = await collection.serialize(item: item)

        XCTAssertGreaterThan(serialized.count, testData.count, "Encrypted data should be larger")

        print("✅ Encrypted \(testData.count) bytes -> \(serialized.count) bytes")
    }

    // MARK: - NTDFStreamingManager Tests

    func testNTDFStreamingManagerInitialization() async throws {
        let manager = NTDFStreamingManager(kasURL: kasURL)

        // Initialize
        try await manager.initialize()

        // Verify state
        let state = await manager.currentState
        XCTAssertEqual(state, .ready, "Manager should be in ready state after initialization")

        // Verify we can get header
        let base64Header = try await manager.getBase64Header()
        XCTAssertFalse(base64Header.isEmpty, "Base64 header should not be empty")

        // Verify base64 decodes back to valid data
        let decoded = Data(base64Encoded: base64Header)
        XCTAssertNotNil(decoded, "Base64 header should decode to valid data")

        print("✅ NTDFStreamingManager initialized, header: \(base64Header.prefix(50))...")

        // Cleanup
        await manager.disconnect()
    }

    // MARK: - Full Streaming Flow Test

    func testFullStreamingFlow() async throws {
        try skipUnlessRTMPServerIsListening()

        let manager = NTDFStreamingManager(kasURL: kasURL)

        // Initialize
        try await manager.initialize()
        print("✅ Step 1: Initialized")

        // Connect to RTMP server
        try await manager.connect(
            rtmpURL: rtmpURL,
            streamKey: testStreamKey,
            width: 1280,
            height: 720,
            framerate: 30.0
        )
        print("✅ Step 2: Connected to RTMP")

        // Send test encrypted frames
        for i in 0..<10 {
            let testData = "Test Frame \(i)".data(using: .utf8)!
            let timestamp = CMTime(value: CMTimeValue(i * 33), timescale: 1000)  // ~30fps

            let frame = EncodedVideoFrame(
                data: testData,
                pts: timestamp,
                isKeyframe: i == 0
            )

            try await manager.sendEncryptedVideo(frame: frame)
        }
        print("✅ Step 3: Sent 10 encrypted frames")

        // Verify stats
        let stats = await manager.statistics
        XCTAssertGreaterThan(stats.bytesSent, 0, "Should have sent some bytes")
        print("✅ Step 4: Stats - bytes sent: \(stats.bytesSent)")

        // Check rotation status
        let needsRotation = await manager.needsRotation
        XCTAssertFalse(needsRotation, "Should not need rotation after only 10 frames")

        // Cleanup
        await manager.disconnect()
        print("✅ Step 5: Disconnected")

        let finalState = await manager.currentState
        XCTAssertEqual(finalState, .idle, "Should be idle after disconnect")
    }

    // MARK: - Metadata Custom Fields Test

    func testMetadataWithCustomFields() async throws {
        // Test that FLVMuxer correctly encodes custom fields
        let metadata = FLVMuxer.createMetadata(
            width: 1920,
            height: 1080,
            framerate: 30.0,
            videoBitrate: 5_000_000,
            audioBitrate: 128_000,
            customFields: ["ntdf_header": "dGVzdA==", "custom_key": "custom_value"]
        )

        // Metadata should contain our custom fields
        // Convert to string to check (AMF0 strings are preceded by length)
        let metadataString = String(data: metadata, encoding: .utf8) ?? ""

        // The custom field names should appear in the metadata
        XCTAssertTrue(metadata.count > 100, "Metadata should contain substantial data")

        print("✅ Metadata with custom fields: \(metadata.count) bytes")
    }

    // MARK: - Error Handling Tests

    func testNotInitializedError() async throws {
        let manager = NTDFStreamingManager(kasURL: kasURL)

        // Try to connect without initializing
        do {
            try await manager.connect(
                rtmpURL: rtmpURL,
                streamKey: "test",
                width: 1920,
                height: 1080,
                framerate: 30.0
            )
            XCTFail("Should have thrown notInitialized error")
        } catch let error as NTDFStreamingError {
            if case .notInitialized = error {
                print("✅ Correctly threw notInitialized error")
            } else {
                XCTFail("Expected notInitialized error, got \(error)")
            }
        }
    }

    func testNotStreamingError() async throws {
        let manager = NTDFStreamingManager(kasURL: kasURL)

        // Initialize but don't connect
        try await manager.initialize()

        // Try to send frame without connecting
        let frame = EncodedVideoFrame(
            data: Data([0x00, 0x01, 0x02]),
            pts: .zero,
            isKeyframe: true
        )

        do {
            try await manager.sendEncryptedVideo(frame: frame)
            XCTFail("Should have thrown notStreaming error")
        } catch let error as NTDFStreamingError {
            if case .notStreaming = error {
                print("✅ Correctly threw notStreaming error")
            } else {
                XCTFail("Expected notStreaming error, got \(error)")
            }
        }

        await manager.disconnect()
    }
}
