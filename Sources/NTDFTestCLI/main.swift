import Foundation
import ArkavoStreaming
import ArkavoMedia
import CoreMedia
import CryptoKit
import OpenTDFKit
import Darwin

/// NTDF Streaming Test CLI
/// Tests NTDF-RTMP streaming outside of XCTest framework

@main
struct NTDFTestCLI {
    // Ensure unbuffered output
    static func setupOutput() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
    }
    static let kasURL = URL(string: "https://100.arkavo.net")!
    static let rtmpURL = "rtmp://localhost:1935"
    static let remoteRtmpURL = "rtmp://100.arkavo.net:1935"
    static let remoteStreamName = "live/creator"

    static func main() async {
        setupOutput()
        // Check command line arguments
        let args = CommandLine.arguments
        let runSubscriberTest = args.contains("--subscriber") || args.contains("-s")
        let runKeyTest = args.contains("--key-test") || args.contains("-k")
        let runPublishTest = args.contains("--publish") || args.contains("-p")
        let runE2ETest = args.contains("--e2e")

        print("============================================")
        print("NTDF Streaming Test CLI")
        print("============================================")
        print("KAS URL: \(kasURL)")
        print("RTMP URL: \(rtmpURL)")
        if runSubscriberTest || runPublishTest || runE2ETest {
            print("Remote RTMP: \(remoteRtmpURL)")
            print("Stream Name: \(remoteStreamName)")
        }
        print("============================================\n")

        if runE2ETest {
            // Run end-to-end test: publisher and subscriber against same server
            do {
                print("--- NTDF End-to-End Test ---")
                try await testEndToEnd()
                print("\n============================================")
                print("E2E TEST COMPLETED!")
                print("============================================")
            } catch {
                print("\n============================================")
                print("E2E TEST FAILED: \(error)")
                print("============================================")
                exit(1)
            }
            return
        }

        if runPublishTest {
            // Publish to remote server
            do {
                print("--- NTDF Publisher Test (Remote) ---")
                try await testPublishRemote()
                print("\n============================================")
                print("PUBLISHER TEST COMPLETED!")
                print("============================================")
            } catch {
                print("\n============================================")
                print("PUBLISHER TEST FAILED: \(error)")
                print("============================================")
                exit(1)
            }
            return
        }

        if runKeyTest {
            // Run key derivation test
            do {
                print("--- NTDF Key Derivation Test ---")
                try await testKeyDerivation()
                print("\n============================================")
                print("KEY TEST COMPLETED!")
                print("============================================")
            } catch {
                print("\n============================================")
                print("KEY TEST FAILED: \(error)")
                print("============================================")
                exit(1)
            }
            return
        }

        if runSubscriberTest {
            // Run subscriber test only
            do {
                print("--- NTDF Subscriber Test ---")
                try await testSubscriber()
                print("\n============================================")
                print("SUBSCRIBER TEST COMPLETED!")
                print("============================================")
            } catch {
                print("\n============================================")
                print("SUBSCRIBER TEST FAILED: \(error)")
                print("============================================")
                exit(1)
            }
            return
        }

        // Run standard tests
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
            print("\nTo run subscriber test: ntdf-test --subscriber")
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

    // MARK: - Subscriber Test

    static func testSubscriber() async throws {
        print("  Step 1: Fetching KAS public key...")
        let kasService = KASPublicKeyService(kasURL: kasURL)
        let kasPublicKey = try await kasService.fetchPublicKey()
        print("  KAS public key: \(kasPublicKey.count) bytes")

        print("\n  Step 2: Generating NTDF token...")
        let tokenBuilder = NTDFTokenBuilder(kasPublicKey: kasPublicKey, kasURL: kasURL.absoluteString)
        let payload = NTDFTokenPayload(
            subId: UUID(),
            flags: [.webAuthn, .profile],
            scopes: ["openid", "profile"],
            iat: Int64(Date().timeIntervalSince1970),
            exp: Int64(Date().timeIntervalSince1970) + 3600,  // 1 hour expiry
            aud: "https://kas.arkavo.net"
        )
        let ntdfToken = try await tokenBuilder.build(payload: payload)
        print("  NTDF token generated: \(ntdfToken.count) chars")
        print("  Token prefix: \(ntdfToken.prefix(50))...")

        print("\n  Step 3: Creating subscriber...")
        let subscriber = NTDFStreamingSubscriber(kasURL: kasURL, ntdfToken: ntdfToken)

        // Track frame statistics using actor for thread safety
        let stats = FrameStatistics()
        let startTime = Date()

        await subscriber.setFrameHandler { frame in
            await stats.recordFrame(frame)
        }

        await subscriber.setStateHandler { state in
            print("  State changed: \(state)")
        }

        print("\n  Step 4: Connecting to \(remoteRtmpURL)/\(remoteStreamName)...")
        try await subscriber.connect(rtmpURL: remoteRtmpURL, streamName: remoteStreamName)

        print("\n  Step 5: Receiving frames for 10 seconds...")
        print("  (Press Ctrl+C to stop early)\n")
        fflush(stdout)

        // Wait for frames
        try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds

        print("\n  Step 6: Disconnecting...")
        await subscriber.disconnect()

        // Print statistics
        let elapsed = Date().timeIntervalSince(startTime)
        let videoFrameCount = await stats.videoFrameCount
        let audioFrameCount = await stats.audioFrameCount
        let totalBytesReceived = await stats.totalBytesReceived

        print("\n  === Statistics ===")
        print("  Duration: \(String(format: "%.1f", elapsed)) seconds")
        print("  Video frames: \(videoFrameCount)")
        print("  Audio frames: \(audioFrameCount)")
        print("  Total bytes: \(totalBytesReceived)")
        if elapsed > 0 {
            let fps = Double(videoFrameCount) / elapsed
            let kbps = Double(totalBytesReceived) * 8 / 1000 / elapsed
            print("  Video FPS: \(String(format: "%.1f", fps))")
            print("  Bitrate: \(String(format: "%.1f", kbps)) kbps")
        }
    }
}

/// Actor for thread-safe frame statistics tracking
actor FrameStatistics {
    var videoFrameCount = 0
    var audioFrameCount = 0
    var totalBytesReceived = 0
    var keyFingerprint: String?

    func recordFrame(_ frame: NTDFStreamingSubscriber.DecryptedFrame) {
        switch frame.type {
        case .video:
            videoFrameCount += 1
            totalBytesReceived += frame.data.count
            if videoFrameCount <= 5 || videoFrameCount % 30 == 0 {
                let isKey = frame.isKeyframe ? " [KEY]" : ""
                print("  [V\(videoFrameCount)] \(frame.data.count) bytes, ts=\(frame.timestamp)\(isKey)")
            }
        case .audio:
            audioFrameCount += 1
            totalBytesReceived += frame.data.count
            if audioFrameCount <= 3 || audioFrameCount % 50 == 0 {
                print("  [A\(audioFrameCount)] \(frame.data.count) bytes, ts=\(frame.timestamp)")
            }
        }
    }

    func setKeyFingerprint(_ fingerprint: String) {
        keyFingerprint = fingerprint
    }

    func getKeyFingerprint() -> String? {
        return keyFingerprint
    }
}

struct TestError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

// MARK: - Key Derivation Test

extension NTDFTestCLI {
    /// Test that publisher and subscriber derive the same symmetric key
    /// This simulates the full flow without RTMP
    static func testKeyDerivation() async throws {
        print("  Step 1: Fetching KAS public key...")
        let kasService = KASPublicKeyService(kasURL: kasURL)
        let kasPublicKey = try await kasService.fetchPublicKey()
        let kasKeyHex = kasPublicKey.map { String(format: "%02X", $0) }.joined()
        print("  KAS public key (\(kasPublicKey.count) bytes): \(kasKeyHex)")

        print("\n  Step 2: Creating NanoTDF collection (simulating publisher)...")
        let kasMetadata = try await kasService.createKasMetadata()

        // Create policy
        let policyUUID = UUID().uuidString.lowercased()
        let policyJSON = """
        {
            "uuid": "\(policyUUID)",
            "body": {
                "dataAttributes": [],
                "dissem": []
            }
        }
        """
        let policyData = policyJSON.data(using: .utf8)!

        let collection = try await NanoTDFCollectionBuilder()
            .kasMetadata(kasMetadata)
            .policy(.embeddedPlaintext(policyData))
            .configuration(.default)
            .build()

        // Get publisher's symmetric key fingerprint
        let publisherKey = await collection.getSymmetricKey()
        let publisherKeyData = publisherKey.withUnsafeBytes { Data($0) }
        let publisherHash = CryptoKit.SHA256.hash(data: publisherKeyData)
        let publisherFingerprint = publisherHash.prefix(8).map { String(format: "%02X", $0) }.joined()
        print("  Publisher symmetric key fingerprint: \(publisherFingerprint)")

        // Get header for subscriber
        let headerBytes = await collection.getHeaderBytes()
        let header = await collection.header
        let ephemeralKey = header.ephemeralPublicKey
        let ephemeralKeyHex = ephemeralKey.map { String(format: "%02X", $0) }.joined()
        print("  Ephemeral public key (\(ephemeralKey.count) bytes): \(ephemeralKeyHex)")
        print("  Header: \(headerBytes.count) bytes")

        print("\n  Step 3: Encrypting test data...")
        let testData = "Hello NTDF Key Test!".data(using: .utf8)!
        let item = try await collection.encryptItem(plaintext: testData)
        let encryptedData = await collection.serialize(item: item)
        print("  Encrypted \(testData.count) bytes -> \(encryptedData.count) bytes")

        print("\n  Step 4: Generating NTDF token for subscriber...")
        let tokenBuilder = NTDFTokenBuilder(kasPublicKey: kasPublicKey, kasURL: kasURL.absoluteString)
        let payload = NTDFTokenPayload(
            subId: UUID(),
            flags: [.webAuthn, .profile],
            scopes: ["openid", "profile"],
            iat: Int64(Date().timeIntervalSince1970),
            exp: Int64(Date().timeIntervalSince1970) + 3600,
            aud: "https://kas.arkavo.net"
        )
        let ntdfToken = try await tokenBuilder.build(payload: payload)
        print("  NTDF token: \(ntdfToken.prefix(50))...")

        print("\n  Step 5: Performing KAS rewrap (simulating subscriber)...")

        // Generate client ephemeral key pair
        let clientPrivateKey = P256.KeyAgreement.PrivateKey()
        let clientKeyPair = EphemeralKeyPair(
            privateKey: clientPrivateKey.rawRepresentation,
            publicKey: clientPrivateKey.publicKey.compressedRepresentation,
            curve: .secp256r1
        )

        // Convert to PEM for KAS
        let clientPubUncompressed = clientPrivateKey.publicKey.x963Representation
        let clientPubPEM = "-----BEGIN PUBLIC KEY-----\n\(clientPubUncompressed.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))-----END PUBLIC KEY-----"
        let pemKeyPair = EphemeralKeyPair(
            privateKey: clientKeyPair.privateKey,
            publicKey: clientPubPEM.data(using: .utf8)!,
            curve: .secp256r1
        )

        // Parse header
        let parser = BinaryParser(data: headerBytes)
        let parsedHeader = try parser.parseHeader()

        // Do KAS rewrap (note: KASRewrapClient appends v2/rewrap, so we need /kas in the URL)
        let kasRewrapURL = URL(string: "https://100.arkavo.net/kas")!
        let kasClient = KASRewrapClient(kasURL: kasRewrapURL, oauthToken: ntdfToken)
        let (wrappedKey, sessionPublicKey) = try await kasClient.rewrapNanoTDF(
            header: headerBytes,
            parsedHeader: parsedHeader,
            clientKeyPair: pemKeyPair
        )
        print("  KAS rewrap successful: wrapped key \(wrappedKey.count) bytes, session key \(sessionPublicKey.count) bytes")

        // Unwrap the key
        let subscriberKey = try KASRewrapClient.unwrapKey(
            wrappedKey: wrappedKey,
            sessionPublicKey: sessionPublicKey,
            clientPrivateKey: clientKeyPair.privateKey
        )
        let subscriberKeyData = subscriberKey.withUnsafeBytes { Data($0) }
        let subscriberHash = CryptoKit.SHA256.hash(data: subscriberKeyData)
        let subscriberFingerprint = subscriberHash.prefix(8).map { String(format: "%02X", $0) }.joined()
        print("  Subscriber symmetric key fingerprint: \(subscriberFingerprint)")

        print("\n  Step 6: Comparing keys...")
        print("  Publisher fingerprint: \(publisherFingerprint)")
        print("  Subscriber fingerprint: \(subscriberFingerprint)")

        if publisherFingerprint == subscriberFingerprint {
            print("  ✅ KEYS MATCH!")

            // Try decryption
            print("\n  Step 7: Testing decryption...")
            let decryptor = NanoTDFCollectionDecryptor.withUnwrappedKey(
                symmetricKey: subscriberKey,
                cipher: .aes256GCM128
            )

            // Parse encrypted item
            let ivCounter = UInt32(encryptedData[0]) << 16 | UInt32(encryptedData[1]) << 8 | UInt32(encryptedData[2])
            let payloadLength = Int(encryptedData[3]) << 16 | Int(encryptedData[4]) << 8 | Int(encryptedData[5])
            let ciphertextWithTag = encryptedData.subdata(in: 6..<(6 + payloadLength))

            let collectionItem = CollectionItem(
                ivCounter: ivCounter,
                ciphertextWithTag: ciphertextWithTag,
                tagSize: 16
            )

            let decrypted = try await decryptor.decryptItem(collectionItem)
            let decryptedString = String(data: decrypted, encoding: .utf8) ?? "<binary>"
            print("  Decrypted: \"\(decryptedString)\"")
            print("  ✅ DECRYPTION SUCCESSFUL!")
        } else {
            print("  ❌ KEYS DO NOT MATCH!")
            print("\n  This indicates KAS is using a different private key than")
            print("  the one corresponding to the public key fetched from /kas/v2/kas_public_key")
            throw TestError("Symmetric key mismatch: publisher=\(publisherFingerprint), subscriber=\(subscriberFingerprint)")
        }
    }

    // MARK: - Remote Publisher Test

    /// Publish NTDF-encrypted frames to remote server
    static func testPublishRemote() async throws {
        print("  Step 1: Fetching KAS public key...")
        let kasService = KASPublicKeyService(kasURL: kasURL)
        let kasPublicKey = try await kasService.fetchPublicKey()
        print("  KAS public key: \(kasPublicKey.count) bytes")

        print("\n  Step 2: Creating NTDFStreamingManager...")
        let manager = NTDFStreamingManager(kasURL: kasURL)
        try await manager.initialize()
        let base64Header = try await manager.getBase64Header()
        print("  NTDF header: \(base64Header.prefix(50))...")

        // Get symmetric key fingerprint
        let symmetricKey = await manager.getSymmetricKeyForTesting()
        if let key = symmetricKey {
            let keyData = key.withUnsafeBytes { Data($0) }
            let hash = CryptoKit.SHA256.hash(data: keyData)
            let fingerprint = hash.prefix(8).map { String(format: "%02X", $0) }.joined()
            print("  Publisher key fingerprint: \(fingerprint)")
        }

        print("\n  Step 3: Creating publisher...")
        let publisher = RTMPPublisher()
        await publisher.setProtocolDebugLogging(true)

        print("\n  Step 4: Connecting to \(remoteRtmpURL)/\(remoteStreamName)...")
        let destination = RTMPPublisher.Destination(url: remoteRtmpURL, platform: "ntdf")
        try await withTimeout(seconds: 15) {
            try await publisher.connect(to: destination, streamKey: remoteStreamName)
        }
        print("  Connected!")

        print("\n  Step 5: Sending metadata with ntdf_header...")
        try await publisher.sendMetadata(
            width: 1280,
            height: 720,
            framerate: 30.0,
            videoBitrate: 2_500_000,
            audioBitrate: 128_000,
            customFields: ["ntdf_header": base64Header]
        )
        print("  Metadata sent!")

        print("\n  Step 6: Sending 30 encrypted test frames...")
        for i in 0..<30 {
            // Create test payload
            let plaintext = "Frame \(i) - Test data for NTDF streaming verification".data(using: .utf8)!
            let encryptedData = try await manager.encrypt(data: plaintext)
            let timestamp = CMTime(value: CMTimeValue(i * 33), timescale: 1000)

            // EncodedVideoFrame.data should be the raw payload (encrypted NTDF item)
            // The FLV header is added by FLVMuxer.createVideoPayload in RTMPPublisher.send(video:)
            let frame = EncodedVideoFrame(
                data: encryptedData,
                pts: timestamp,
                isKeyframe: i == 0 || i % 30 == 0
            )

            try await publisher.send(video: frame)
            if i <= 5 || i % 10 == 0 {
                print("    Sent frame \(i): \(encryptedData.count) encrypted bytes")
            }

            try await Task.sleep(nanoseconds: 33_000_000)  // ~30fps
        }
        print("  Frames sent!")

        print("\n  Step 7: Disconnecting...")
        await publisher.disconnect()
        await manager.disconnect()
        print("  Done!")
    }

    // MARK: - End-to-End Test

    /// Run publisher and subscriber concurrently against same server
    static func testEndToEnd() async throws {
        print("  Step 1: Fetching KAS public key...")
        let kasService = KASPublicKeyService(kasURL: kasURL)
        let kasPublicKey = try await kasService.fetchPublicKey()
        print("  KAS public key: \(kasPublicKey.count) bytes")

        print("\n  Step 2: Creating NTDF token for subscriber...")
        let tokenBuilder = NTDFTokenBuilder(kasPublicKey: kasPublicKey, kasURL: kasURL.absoluteString)
        let payload = NTDFTokenPayload(
            subId: UUID(),
            flags: [.webAuthn, .profile],
            scopes: ["openid", "profile"],
            iat: Int64(Date().timeIntervalSince1970),
            exp: Int64(Date().timeIntervalSince1970) + 3600,
            aud: "https://kas.arkavo.net"
        )
        let ntdfToken = try await tokenBuilder.build(payload: payload)
        print("  Token: \(ntdfToken.prefix(40))...")

        print("\n  Step 3: Creating NTDFStreamingManager for publisher...")
        let manager = NTDFStreamingManager(kasURL: kasURL)
        try await manager.initialize()
        let base64Header = try await manager.getBase64Header()

        // Get publisher's key fingerprint
        var publisherFingerprint = ""
        if let key = await manager.getSymmetricKeyForTesting() {
            let keyData = key.withUnsafeBytes { Data($0) }
            let hash = CryptoKit.SHA256.hash(data: keyData)
            publisherFingerprint = hash.prefix(8).map { String(format: "%02X", $0) }.joined()
            print("  Publisher key fingerprint: \(publisherFingerprint)")
        }

        // Use unique stream name to avoid conflicts with existing streams
        let uniqueStreamName = "live/e2e-test-\(Int(Date().timeIntervalSince1970))"
        print("  Using unique stream: \(uniqueStreamName)")

        print("\n  Step 4: Starting publisher FIRST...")
        let publisher = RTMPPublisher()

        let destination = RTMPPublisher.Destination(url: remoteRtmpURL, platform: "ntdf")
        try await withTimeout(seconds: 15) {
            try await publisher.connect(to: destination, streamKey: uniqueStreamName)
        }
        print("  [PUB] Connected!")

        // Send metadata with ntdf_header
        try await publisher.sendMetadata(
            width: 1280,
            height: 720,
            framerate: 30.0,
            videoBitrate: 2_500_000,
            audioBitrate: 128_000,
            customFields: ["ntdf_header": base64Header]
        )
        print("  [PUB] Metadata sent with ntdf_header!")

        // Give server time to register the stream
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

        print("\n  Step 5: Starting subscriber...")
        let subscriber = NTDFStreamingSubscriber(kasURL: kasURL, ntdfToken: ntdfToken)
        let stats = FrameStatistics()
        var subscriberFingerprint = ""

        await subscriber.setFrameHandler { frame in
            await stats.recordFrame(frame)
        }

        await subscriber.setStateHandler { state in
            print("  [SUB] State: \(state)")
        }

        // Start subscriber in background
        let subscriberTask = Task {
            do {
                try await subscriber.connect(rtmpURL: remoteRtmpURL, streamName: uniqueStreamName)
                // Wait for frames
                try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
            } catch {
                print("  [SUB] Error: \(error)")
            }
        }

        // Give subscriber time to connect and receive metadata
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds

        print("\n  Step 6: Sending frames...")
        for i in 0..<60 {
            let plaintext = "Frame \(i) - E2E test data".data(using: .utf8)!
            let encryptedData = try await manager.encrypt(data: plaintext)
            let timestamp = CMTime(value: CMTimeValue(i * 33), timescale: 1000)

            // EncodedVideoFrame.data should be the raw payload (encrypted NTDF item)
            // The FLV header is added by FLVMuxer.createVideoPayload in RTMPPublisher.send(video:)
            let frame = EncodedVideoFrame(
                data: encryptedData,
                pts: timestamp,
                isKeyframe: i == 0 || i % 30 == 0
            )

            try await publisher.send(video: frame)
            if i <= 3 || i % 20 == 0 {
                print("  [PUB] Frame \(i): \(encryptedData.count) bytes")
            }

            try await Task.sleep(nanoseconds: 33_000_000)
        }

        print("\n  Step 7: Waiting for subscriber...")
        await subscriberTask.value

        print("\n  Step 8: Cleaning up...")
        await publisher.disconnect()
        await subscriber.disconnect()
        await manager.disconnect()

        // Get subscriber's key fingerprint from stats
        subscriberFingerprint = await stats.getKeyFingerprint() ?? "unknown"

        // Print results
        let videoCount = await stats.videoFrameCount
        let audioCount = await stats.audioFrameCount
        let totalBytes = await stats.totalBytesReceived

        print("\n  === Results ===")
        print("  Publisher fingerprint: \(publisherFingerprint)")
        print("  Subscriber fingerprint: \(subscriberFingerprint)")
        print("  Video frames received: \(videoCount)")
        print("  Audio frames received: \(audioCount)")
        print("  Total bytes: \(totalBytes)")

        if videoCount > 0 {
            print("  ✅ Subscriber received decrypted frames!")
        } else {
            print("  ⚠️ No frames received - check logs above for errors")
        }
    }
}
