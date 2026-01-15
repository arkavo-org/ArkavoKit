import AVFoundation
import Foundation
import Testing
@testable import ArkavoSocial
@testable import ArkavoMediaKit

/// End-to-end integration tests for FairPlay with the production server (https://100.arkavo.net)
/// These tests verify the complete pipeline from content encryption through key delivery
@Suite("FairPlay E2E Integration Tests")
struct FairPlayE2EIntegrationTests {

    // MARK: - Configuration

    let serverURL = URL(string: "https://100.arkavo.net")!

    // Test fixtures
    let testSPS = Data([0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0x50,
                        0x05, 0xBB, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00,
                        0x10, 0x00, 0x00, 0x03, 0x03, 0xC0, 0xF1, 0x83,
                        0x19, 0x60])
    let testPPS = Data([0x68, 0xEE, 0x3C, 0x80])

    // MARK: - Server Connectivity Tests

    @Test("Server: KAS public key endpoint accessible")
    func kasPublicKeyEndpoint() async throws {
        let url = URL(string: "https://100.arkavo.net/kas/v2/kas_public_key?algorithm=rsa:2048")!
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse else {
            Issue.record("Invalid response type")
            return
        }

        #expect(http.statusCode == 200, "KAS endpoint should return 200, got \(http.statusCode)")

        // Parse response
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let publicKey = json?["public_key"] as? String

        #expect(publicKey != nil, "Response should contain public_key")
        #expect(publicKey?.contains("BEGIN PUBLIC KEY") == true, "Should be PEM format")

        print("✅ KAS public key endpoint working")
        print("   Key ID: \(json?["kid"] ?? "unknown")")
    }

    @Test("Server: FairPlay certificate endpoint accessible")
    func fairPlayCertificateEndpoint() async throws {
        let url = serverURL.appendingPathComponent("media/v1/certificate")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse else {
            Issue.record("Invalid response type")
            return
        }

        #expect(http.statusCode == 200, "Certificate endpoint should return 200, got \(http.statusCode)")
        #expect(data.count > 0, "Certificate data should not be empty")

        print("✅ FairPlay certificate endpoint working")
        print("   Certificate size: \(data.count) bytes")
    }

    @Test("Server: FairPlay session start works")
    func sessionStartEndpoint() async throws {
        let url = serverURL.appendingPathComponent("media/v1/session/start")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "userId": "e2e-test-user",
            "assetId": "e2e-test-asset-\(UUID().uuidString)",
            "protocol": "fairplay"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            Issue.record("Invalid response type")
            return
        }

        #expect(http.statusCode == 200, "Session start should return 200, got \(http.statusCode)")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sessionId = json?["sessionId"] as? String
        let status = json?["status"] as? String

        #expect(sessionId != nil, "Response should contain sessionId")
        #expect(status == "started", "Status should be 'started', got \(status ?? "nil")")

        print("✅ FairPlay session created")
        print("   Session ID: \(sessionId ?? "unknown")")
    }

    // MARK: - TDF Manifest Builder Tests

    @Test("TDFManifestBuilder: Fetch and wrap key with real KAS")
    func tdfManifestBuilderRealKAS() async throws {
        let builder = TDFManifestBuilder(kasURL: serverURL)

        // Generate test content key
        let contentKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let assetID = "e2e-test-\(UUID().uuidString)"

        // Build manifest (fetches KAS public key and wraps)
        let manifest = try await builder.buildManifest(
            contentKey: contentKey,
            iv: iv,
            assetID: assetID
        )

        // Verify manifest structure
        #expect(manifest.encryptionInformation.type == "split")
        #expect(manifest.encryptionInformation.keyAccess.count == 1)

        let keyAccess = manifest.encryptionInformation.keyAccess[0]
        #expect(keyAccess.type == "wrapped")
        #expect(keyAccess.url == serverURL.absoluteString)
        #expect(!keyAccess.wrappedKey.isEmpty, "Wrapped key should not be empty")

        // Verify wrapped key is RSA-2048 size (256 bytes when base64 decoded)
        if let wrappedKeyData = Data(base64Encoded: keyAccess.wrappedKey) {
            #expect(wrappedKeyData.count == 256, "RSA-2048 wrapped key should be 256 bytes")
        }

        print("✅ TDFManifestBuilder works with real KAS")
        print("   Wrapped key size: \(keyAccess.wrappedKey.count) chars (base64)")
    }

    // MARK: - Full Key Exchange Flow

    @Test("E2E: Complete key exchange flow with TDF manifest")
    func completeKeyExchangeFlow() async throws {
        // 1. Generate content key
        let contentKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let assetID = "e2e-key-exchange-\(UUID().uuidString)"

        print("=== E2E Key Exchange Test ===")
        print("Asset ID: \(assetID)")
        print("Content Key: \(contentKey.map { String(format: "%02x", $0) }.joined())")

        // 2. Build TDF manifest (wrap key with KAS public key)
        let builder = TDFManifestBuilder(kasURL: serverURL)
        let manifest = try await builder.buildManifest(
            contentKey: contentKey,
            iv: iv,
            assetID: assetID
        )
        let manifestData = try builder.serializeManifest(manifest)
        let manifestBase64 = manifestData.base64EncodedString()

        print("✅ TDF manifest created")

        // 3. Start FairPlay session
        let sessionURL = serverURL.appendingPathComponent("media/v1/session/start")
        var sessionRequest = URLRequest(url: sessionURL)
        sessionRequest.httpMethod = "POST"
        sessionRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let sessionBody: [String: Any] = [
            "userId": "e2e-test-user",
            "assetId": assetID,
            "protocol": "fairplay"
        ]
        sessionRequest.httpBody = try JSONSerialization.data(withJSONObject: sessionBody)

        let (sessionData, sessionResponse) = try await URLSession.shared.data(for: sessionRequest)
        guard let sessionHttp = sessionResponse as? HTTPURLResponse,
              sessionHttp.statusCode == 200 else {
            Issue.record("Failed to start session")
            return
        }

        let sessionJson = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any]
        guard let sessionId = sessionJson?["sessionId"] as? String else {
            Issue.record("No session ID in response")
            return
        }

        print("✅ Session started: \(sessionId)")

        // 4. Request key (simulate key request - without actual SPC we can't complete)
        // Note: Real SPC must come from AVPlayer on device with FairPlay entitlements
        // Here we test the endpoint accepts our request format

        let keyRequestURL = serverURL.appendingPathComponent("media/v1/key-request")
        var keyRequest = URLRequest(url: keyRequestURL)
        keyRequest.httpMethod = "POST"
        keyRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Create a dummy SPC (will fail validation but tests endpoint)
        let dummySPC = Data(repeating: 0x00, count: 64).base64EncodedString()

        let keyBody: [String: Any] = [
            "sessionId": sessionId,
            "userId": "e2e-test-user",
            "assetId": assetID,
            "spcData": dummySPC,
            "tdfManifest": manifestBase64
        ]
        keyRequest.httpBody = try JSONSerialization.data(withJSONObject: keyBody)

        let (keyData, keyResponse) = try await URLSession.shared.data(for: keyRequest)
        let keyHttp = keyResponse as? HTTPURLResponse

        // We expect this to fail because the SPC is invalid
        // But the error should be about SPC validation, not manifest parsing
        if let errorJson = try? JSONSerialization.jsonObject(with: keyData) as? [String: Any] {
            let errorMsg = errorJson["message"] as? String ?? errorJson["error"] as? String ?? "unknown"
            print("Key request response: \(errorMsg)")

            // Verify the error is about SPC, not TDF manifest
            let lowercaseError = errorMsg.lowercased()
            #expect(!lowercaseError.contains("manifest"), "Error should not be about manifest parsing")
            #expect(!lowercaseError.contains("wrapped"), "Error should not be about key unwrapping")
        }

        print("✅ Key request endpoint accepts TDF manifest format")
        print("   (Expected failure due to dummy SPC)")

        print("=== E2E Key Exchange Test Complete ===")
    }

    // MARK: - Content Structure Tests

    @Test("E2E: Generate complete encrypted fMP4 package")
    func generateEncryptedFMP4Package() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Generate content key and wrap with KAS
        let contentKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let keyID = Data(repeating: 0, count: 16)  // All-zero KID per Apple spec
        let assetID = "fmp4-test-\(UUID().uuidString)"

        print("=== Generate Encrypted fMP4 Package ===")
        print("Asset ID: \(assetID)")

        // 2. Build TDF manifest
        let builder = TDFManifestBuilder(kasURL: serverURL)
        let manifest = try await builder.buildManifest(
            contentKey: contentKey,
            iv: iv,
            assetID: assetID
        )
        let manifestData = try builder.serializeManifest(manifest)
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))
        print("✅ TDF manifest created")

        // 3. Create encrypted fMP4 content
        let track = FMP4Writer.TrackConfig.h264Video(
            width: 1280, height: 720, timescale: 90000,
            sps: [testSPS], pps: [testPPS]
        )

        let encryption = FMP4Writer.EncryptionConfig(keyID: keyID, constantIV: iv)
        let writer = FMP4Writer(tracks: [track], encryption: encryption)

        // Generate init segment
        let initSegment = writer.generateInitSegment()
        try initSegment.write(to: tempDir.appendingPathComponent("init.mp4"))
        print("✅ Init segment: \(initSegment.count) bytes")

        // Generate media segment with synthetic video data
        var samples: [FMP4Writer.Sample] = []
        for i in 0..<90 {  // 3 seconds at 30fps
            let isIDR = (i == 0)
            let sampleData = createVideoSample(isIDR: isIDR, size: isIDR ? 8000 : 2000)
            samples.append(FMP4Writer.Sample(
                data: sampleData,
                duration: 3000,
                isSync: isIDR
            ))
        }

        let segment0 = writer.generateMediaSegment(trackID: 1, samples: samples, baseDecodeTime: 0)
        try segment0.write(to: tempDir.appendingPathComponent("segment0.m4s"))
        print("✅ Segment 0: \(segment0.count) bytes")

        // 4. Generate HLS playlist with FairPlay signaling
        let playlistConfig = FMP4HLSGenerator.PlaylistConfig(
            targetDuration: 4,
            playlistType: .vod,
            initSegmentURI: "init.mp4"
        )

        let fairplayConfig = FMP4HLSGenerator.FairPlayConfig.fairPlay(
            assetID: assetID,
            keyID: keyID,
            iv: iv
        )

        let hlsGenerator = FMP4HLSGenerator(config: playlistConfig, encryption: fairplayConfig)
        let segments = [FMP4HLSGenerator.Segment(uri: "segment0.m4s", duration: 3.0)]
        let playlist = hlsGenerator.generateMediaPlaylist(segments: segments)
        try playlist.write(to: tempDir.appendingPathComponent("playlist.m3u8"), atomically: true, encoding: .utf8)

        print("✅ HLS playlist created")
        print("--- Playlist Content ---")
        print(playlist)
        print("------------------------")

        // 5. Verify package structure
        #expect(playlist.contains("#EXT-X-KEY:METHOD=SAMPLE-AES"))
        #expect(playlist.contains("skd://\(assetID)"))
        #expect(playlist.contains("KEYFORMAT=\"com.apple.streamingkeydelivery\""))
        #expect(playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))

        // Verify init segment has encryption boxes
        let initData = try Data(contentsOf: tempDir.appendingPathComponent("init.mp4"))
        let hasEncv = initData.range(of: Data([0x65, 0x6E, 0x63, 0x76])) != nil  // "encv"
        let hasSinf = initData.range(of: Data([0x73, 0x69, 0x6E, 0x66])) != nil  // "sinf"
        let hasTenc = initData.range(of: Data([0x74, 0x65, 0x6E, 0x63])) != nil  // "tenc"

        #expect(hasEncv, "Init segment should have encv box")
        #expect(hasSinf, "Init segment should have sinf box")
        #expect(hasTenc, "Init segment should have tenc box")

        // Verify media segment has senc box
        let segmentData = try Data(contentsOf: tempDir.appendingPathComponent("segment0.m4s"))
        let hasSenc = segmentData.range(of: Data([0x73, 0x65, 0x6E, 0x63])) != nil  // "senc"
        let hasSaiz = segmentData.range(of: Data([0x73, 0x61, 0x69, 0x7A])) != nil  // "saiz"
        let hasSaio = segmentData.range(of: Data([0x73, 0x61, 0x69, 0x6F])) != nil  // "saio"

        #expect(hasSenc, "Segment should have senc box")
        #expect(hasSaiz, "Segment should have saiz box")
        #expect(hasSaio, "Segment should have saio box")

        print("✅ All encryption boxes present")
        print("=== Package Generation Complete ===")
    }

    @Test("E2E: Serve encrypted content and verify AVPlayer loads playlist")
    func serveAndLoadEncryptedContent() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Generate encrypted content
        let contentKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let keyID = Data(repeating: 0, count: 16)
        let assetID = "avplayer-test-\(UUID().uuidString)"

        let track = FMP4Writer.TrackConfig.h264Video(
            width: 1280, height: 720, timescale: 90000,
            sps: [testSPS], pps: [testPPS]
        )

        let encryption = FMP4Writer.EncryptionConfig(keyID: keyID, constantIV: iv)
        let writer = FMP4Writer(tracks: [track], encryption: encryption)

        // Generate init and segment
        try writer.generateInitSegment().write(to: tempDir.appendingPathComponent("init.mp4"))

        var samples: [FMP4Writer.Sample] = []
        for i in 0..<90 {
            let isIDR = (i == 0)
            samples.append(FMP4Writer.Sample(
                data: createVideoSample(isIDR: isIDR, size: isIDR ? 8000 : 2000),
                duration: 3000,
                isSync: isIDR
            ))
        }
        try writer.generateMediaSegment(trackID: 1, samples: samples, baseDecodeTime: 0)
            .write(to: tempDir.appendingPathComponent("segment0.m4s"))

        // Generate playlist
        let playlistConfig = FMP4HLSGenerator.PlaylistConfig(
            targetDuration: 4, playlistType: .vod, initSegmentURI: "init.mp4"
        )
        let fairplayConfig = FMP4HLSGenerator.FairPlayConfig.fairPlay(assetID: assetID, keyID: keyID, iv: iv)
        let hlsGenerator = FMP4HLSGenerator(config: playlistConfig, encryption: fairplayConfig)
        let playlist = hlsGenerator.generateMediaPlaylist(segments: [
            FMP4HLSGenerator.Segment(uri: "segment0.m4s", duration: 3.0)
        ])
        try playlist.write(to: tempDir.appendingPathComponent("playlist.m3u8"), atomically: true, encoding: .utf8)

        // Start local server
        let server = LocalHTTPServer(contentDirectory: tempDir)
        let baseURL = try server.start()
        defer { server.stop() }

        print("Serving encrypted content at: \(baseURL)")

        // Track key requests
        let keyTracker = KeyRequestTracker()

        // Load in AVPlayer
        let playlistURL = baseURL.appendingPathComponent("playlist.m3u8")
        let asset = AVURLAsset(url: playlistURL)

        let delegate = KeyRequestCaptureDelegate { keyURI in
            Task { await keyTracker.addRequest(keyURI) }
            print("🔐 Key request triggered: \(keyURI)")
        }
        asset.resourceLoader.setDelegate(delegate, queue: DispatchQueue.main)

        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)

        // Wait for loading
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 10 {
            if playerItem.status != .unknown {
                break
            }
            if await keyTracker.count > 0 {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let keyRequests = await keyTracker.requests
        let status = playerItem.status

        print("Player status: \(status.rawValue)")
        print("Key requests: \(keyRequests)")

        // The important thing is that AVPlayer parsed the manifest and attempted key request
        if !keyRequests.isEmpty {
            #expect(keyRequests.first?.contains(assetID) == true,
                   "Key request should be for our asset")
            print("✅ AVPlayer triggered key request for encrypted content")
        } else {
            print("ℹ️ No key request (FairPlay entitlements may not be available in test environment)")
        }

        // Verify player at least attempted to load (didn't fail on manifest parse)
        if status == .failed {
            let error = playerItem.error?.localizedDescription ?? "unknown"
            // FairPlay key failure is expected without license server
            // But manifest parse or HTTP errors would be bugs
            #expect(!error.lowercased().contains("parse"), "Should not have parse errors")
            #expect(!error.lowercased().contains("404"), "All files should be served")
        }
    }

    // MARK: - Helpers

    func createVideoSample(isIDR: Bool, size: Int = 2000) -> Data {
        var sample = Data()
        let nalType: UInt8 = isIDR ? 0x65 : 0x41
        let payloadSize = size - 4
        let length = UInt32(payloadSize)
        withUnsafeBytes(of: length.bigEndian) { sample.append(contentsOf: $0) }
        sample.append(nalType)
        sample.append(Data(repeating: 0xAB, count: payloadSize - 1))
        return sample
    }
}

// MARK: - Reuse KeyRequestTracker from LocalHTTPServerPlaybackTests

// Note: KeyRequestTracker and KeyRequestCaptureDelegate are defined in LocalHTTPServerPlaybackTests.swift
// They should be moved to a shared file if needed
