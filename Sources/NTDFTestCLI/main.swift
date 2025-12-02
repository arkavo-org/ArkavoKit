import Foundation
import ArkavoStreaming
import ArkavoMedia
import CoreMedia
import OpenTDFKit

/// NTDF Streaming Test CLI
/// Tests NTDF-RTMP streaming outside of XCTest framework

@main
struct NTDFTestCLI {
    static let kasURL = URL(string: "https://100.arkavo.net")!
    static let rtmpURL = "rtmp://localhost:1935"

    static func main() async {
        print("============================================")
        print("NTDF Streaming Test CLI")
        print("============================================")
        print("KAS URL: \(kasURL)")
        print("RTMP URL: \(rtmpURL)")
        print("============================================\n")

        do {
            // Test 1: KAS Public Key
            print("--- Test 1: KAS Public Key Fetch ---")
            try await testKASPublicKey()
            print()

            // Test 2: Collection Creation
            print("--- Test 2: NanoTDF Collection ---")
            try await testCollection()
            print()

            // Test 3: NTDFStreamingManager Init
            print("--- Test 3: NTDFStreamingManager Init ---")
            try await testStreamingManagerInit()
            print()

            // Test 4: Full Streaming Flow
            print("--- Test 4: Full Streaming Flow ---")
            try await testFullStreamingFlow()
            print()

            print("============================================")
            print("ALL TESTS PASSED!")
            print("============================================")
        } catch {
            print("\n============================================")
            print("TEST FAILED: \(error)")
            print("============================================")
            exit(1)
        }
    }

    static func testKASPublicKey() async throws {
        let kasService = KASPublicKeyService(kasURL: kasURL)
        let publicKey = try await kasService.fetchPublicKey()

        guard publicKey.count == 33 else {
            throw TestError("Expected 33-byte compressed P-256 key, got \(publicKey.count)")
        }

        let prefix = publicKey[0]
        guard prefix == 0x02 || prefix == 0x03 else {
            throw TestError("Expected compressed point prefix (0x02 or 0x03), got 0x\(String(format: "%02x", prefix))")
        }

        print("  KAS public key: \(publicKey.map { String(format: "%02x", $0) }.joined().prefix(20))...")
    }

    static func testCollection() async throws {
        let kasService = KASPublicKeyService(kasURL: kasURL)
        let kasMetadata = try await kasService.createKasMetadata()

        let collection = try await NanoTDFCollectionBuilder()
            .kasMetadata(kasMetadata)
            .policy(.embeddedPlaintext(Data()))
            .configuration(.default)
            .build()

        let headerBytes = await collection.getHeaderBytes()
        guard headerBytes.count > 0 else {
            throw TestError("Header bytes should not be empty")
        }

        // Test encryption
        let testData = "Hello NTDF-RTMP!".data(using: .utf8)!
        let item = try await collection.encryptItem(plaintext: testData)
        let serialized = await collection.serialize(item: item)

        guard serialized.count > testData.count else {
            throw TestError("Encrypted data should be larger than plaintext")
        }

        print("  Header: \(headerBytes.count) bytes")
        print("  Encrypted \(testData.count) bytes -> \(serialized.count) bytes")
    }

    static func testStreamingManagerInit() async throws {
        let manager = NTDFStreamingManager(kasURL: kasURL)
        try await manager.initialize()

        let state = await manager.currentState
        guard state == .ready else {
            throw TestError("Expected .ready state, got \(state)")
        }

        let base64Header = try await manager.getBase64Header()
        guard !base64Header.isEmpty else {
            throw TestError("Base64 header should not be empty")
        }

        guard Data(base64Encoded: base64Header) != nil else {
            throw TestError("Base64 header should decode to valid data")
        }

        print("  State: ready")
        print("  Header: \(base64Header.prefix(50))...")

        await manager.disconnect()
    }

    static func testFullStreamingFlow() async throws {
        let streamKey = "live/test-ntdf-\(UUID().uuidString.prefix(8))"
        print("  Stream key: \(streamKey)")

        // Test using RTMPPublisher directly with more control
        let publisher = RTMPPublisher()

        // Enable debug logging
        await publisher.setProtocolDebugLogging(true)

        print("  Step 1: Connecting to RTMP (15s timeout)...")
        let destination = RTMPPublisher.Destination(url: rtmpURL, platform: "ntdf")

        try await withTimeout(seconds: 15) {
            try await publisher.connect(to: destination, streamKey: streamKey)
        }
        print("  Step 1: Connected!")

        // Send metadata
        print("  Step 2: Sending metadata...")
        try await publisher.sendMetadata(
            width: 1280,
            height: 720,
            framerate: 30.0,
            videoBitrate: 2_500_000,
            audioBitrate: 128_000,
            customFields: ["ntdf_header": "dGVzdF9oZWFkZXI="]
        )
        print("  Step 2: Metadata sent!")

        // Send test frames
        print("  Step 3: Sending 5 test frames...")
        for i in 0..<5 {
            let testData = "Test Frame \(i) - padding data to make it larger".data(using: .utf8)!
            let timestamp = CMTime(value: CMTimeValue(i * 33), timescale: 1000)

            let frame = EncodedVideoFrame(
                data: testData,
                pts: timestamp,
                isKeyframe: i == 0
            )

            try await publisher.send(video: frame)
            print("    Sent frame \(i)")

            // Small delay between frames
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }
        print("  Step 3: Frames sent!")

        // Get stats
        let stats = await publisher.statistics
        print("  Step 4: Bytes sent: \(stats.bytesSent)")

        // Disconnect
        print("  Step 5: Disconnecting...")
        await publisher.disconnect()
        print("  Step 5: Done!")
    }

    static func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TestError("Operation timed out after \(seconds) seconds")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

struct TestError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
