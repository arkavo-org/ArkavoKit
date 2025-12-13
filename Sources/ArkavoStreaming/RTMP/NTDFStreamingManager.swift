import CryptoKit
import Foundation
import OpenTDFKit
import ArkavoMedia
import CoreMedia

/// Error types for NTDF streaming operations
public enum NTDFStreamingError: Error, LocalizedError {
    case notInitialized
    case notStreaming
    case kasConnectionFailed(String)
    case collectionCreationFailed(String)
    case encryptionFailed(String)
    case rtmpConnectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "NTDFStreamingManager not initialized - call initialize() first"
        case .notStreaming:
            return "Not currently streaming"
        case .kasConnectionFailed(let message):
            return "KAS connection failed: \(message)"
        case .collectionCreationFailed(let message):
            return "Failed to create NanoTDF collection: \(message)"
        case .encryptionFailed(let message):
            return "Encryption failed: \(message)"
        case .rtmpConnectionFailed(let message):
            return "RTMP connection failed: \(message)"
        }
    }
}

/// Manager for NTDF-encrypted RTMP streaming
/// Combines NanoTDF encryption with RTMPPublisher
public actor NTDFStreamingManager {

    /// Current state of the streaming manager
    public enum State: Sendable, Equatable {
        case idle
        case initializing
        case ready
        case streaming
        case error(String)
    }

    private let kasService: KASPublicKeyService
    private let rtmpPublisher: RTMPPublisher
    private var collection: NanoTDFCollection?
    private var state: State = .idle
    private var cachedHeaderBytes: Data?

    // Store stream parameters for metadata updates on key rotation
    private var streamWidth: Int = 0
    private var streamHeight: Int = 0
    private var streamFramerate: Double = 0
    private var streamVideoBitrate: Double = 0
    private var streamAudioBitrate: Double = 0

    /// Current state of the manager
    public var currentState: State { state }

    /// Initialize with KAS URL
    /// - Parameter kasURL: The KAS server URL (e.g., https://100.arkavo.net)
    public init(kasURL: URL) {
        self.kasService = KASPublicKeyService(kasURL: kasURL)
        self.rtmpPublisher = RTMPPublisher()
    }

    /// Initialize encryption: fetch KAS key and create NanoTDF Collection
    /// - Parameter policy: Policy data (if nil, creates default open-access policy)
    public func initialize(policy: Data? = nil) async throws {
        state = .initializing

        do {
            // 1. Fetch KAS public key and create metadata
            print("🔐 Initializing NTDF streaming...")
            let kasMetadata = try await kasService.createKasMetadata()

            // Log KAS public key for debugging
            let kasPublicKeyData = try kasMetadata.getPublicKey()
            let kasKeyHex = kasPublicKeyData.map { String(format: "%02X", $0) }.joined()
            print("🔐 [DEBUG] KAS public key (\(kasPublicKeyData.count) bytes): \(kasKeyHex)")

            // 2. Create policy data - must be valid JSON, not empty
            let policyData: Data
            if let policy = policy, !policy.isEmpty {
                policyData = policy
            } else {
                // Create default open-access policy (required by KAS)
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
                policyData = policyJSON.data(using: .utf8)!
                print("🔐 Using default open-access policy: \(policyUUID)")
            }

            // 3. Build NanoTDF Collection (uses v12 L1L format by default)
            collection = try await NanoTDFCollectionBuilder()
                .kasMetadata(kasMetadata)
                .policy(.embeddedPlaintext(policyData))
                .configuration(.default)
                .build()

            // Log key fingerprint for debugging (SHA256 of key, first 8 bytes)
            if let collection = collection {
                let symmetricKey = await collection.getSymmetricKey()
                let keyData = symmetricKey.withUnsafeBytes { Data($0) }
                let keyHash = CryptoKit.SHA256.hash(data: keyData)
                let keyFingerprint = keyHash.prefix(8).map { String(format: "%02X", $0) }.joined()
                print("🔐 [NTDFStreamingManager] Symmetric key fingerprint: \(keyFingerprint)")
            }

            state = .ready
            print("✅ NTDF streaming initialized")
        } catch {
            state = .error(error.localizedDescription)
            throw NTDFStreamingError.collectionCreationFailed(error.localizedDescription)
        }
    }

    /// Connect to RTMP server and send metadata with ntdf_header
    /// - Parameters:
    ///   - rtmpURL: RTMP server URL (e.g., rtmp://100.arkavo.net:1935)
    ///   - streamKey: Stream key (e.g., live/test)
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    ///   - framerate: Video framerate (fps)
    ///   - videoBitrate: Video bitrate in bits/sec (default 2.5 Mbps)
    ///   - audioBitrate: Audio bitrate in bits/sec (default 128 kbps)
    public func connect(
        rtmpURL: String,
        streamKey: String,
        width: Int,
        height: Int,
        framerate: Double,
        videoBitrate: Double = 2_500_000,
        audioBitrate: Double = 128_000
    ) async throws {
        guard let collection else {
            throw NTDFStreamingError.notInitialized
        }

        print("📡 Connecting to RTMP: \(rtmpURL)/\(streamKey)")

        // Store stream parameters for metadata updates on key rotation
        self.streamWidth = width
        self.streamHeight = height
        self.streamFramerate = framerate
        self.streamVideoBitrate = videoBitrate
        self.streamAudioBitrate = audioBitrate

        // Get header bytes and encode as base64
        let headerBytes = await collection.getHeaderBytes()
        let base64Header = headerBytes.base64EncodedString()

        print("📋 NanoTDF header: \(headerBytes.count) bytes -> \(base64Header.count) chars base64")

        // Connect to RTMP
        let destination = RTMPPublisher.Destination(url: rtmpURL, platform: "ntdf")
        do {
            try await rtmpPublisher.connect(to: destination, streamKey: streamKey)
        } catch {
            throw NTDFStreamingError.rtmpConnectionFailed(error.localizedDescription)
        }

        // Send metadata with ntdf_header
        try await rtmpPublisher.sendMetadata(
            width: width,
            height: height,
            framerate: framerate,
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate,
            customFields: ["ntdf_header": base64Header]
        )

        // Cache header bytes for periodic re-transmission
        cachedHeaderBytes = headerBytes

        // Send NTDF header as first video data frame with special marker
        // This bypasses RTMP server metadata stripping
        try await sendNTDFHeaderFrame(headerBytes)

        state = .streaming
        print("✅ NTDF streaming started with embedded header")
    }

    /// Encrypt and send video frame
    /// - Parameter frame: The video frame to encrypt and send
    public func sendEncryptedVideo(frame: EncodedVideoFrame) async throws {
        guard collection != nil, state == .streaming else {
            throw NTDFStreamingError.notStreaming
        }

        do {
            // Create NEW collection (new key) for each keyframe - IV resets to 1
            if frame.isKeyframe {
                try await rotateCollection()
            }

            guard let collection else {
                throw NTDFStreamingError.notStreaming
            }

            // Encrypt the video frame data
            let item = try await collection.encryptItem(plaintext: frame.data)

            // Serialize to wire format (containerFraming: IV + length + ciphertext+tag)
            let encryptedData = await collection.serialize(item: item)

            // Create modified frame with encrypted payload
            let encryptedFrame = EncodedVideoFrame(
                data: encryptedData,
                pts: frame.pts,
                isKeyframe: frame.isKeyframe,
                formatDescription: frame.formatDescription
            )

            // Send via RTMP
            try await rtmpPublisher.send(video: encryptedFrame)
        } catch {
            throw NTDFStreamingError.encryptionFailed(error.localizedDescription)
        }
    }

    /// Encrypt and send audio frame
    /// - Parameter frame: The audio frame to encrypt and send
    public func sendEncryptedAudio(frame: EncodedAudioFrame) async throws {
        guard let collection, state == .streaming else {
            throw NTDFStreamingError.notStreaming
        }

        do {
            // Encrypt audio data
            let item = try await collection.encryptItem(plaintext: frame.data)
            let encryptedData = await collection.serialize(item: item)

            let encryptedFrame = EncodedAudioFrame(
                data: encryptedData,
                pts: frame.pts,
                formatDescription: frame.formatDescription
            )

            try await rtmpPublisher.send(audio: encryptedFrame)
        } catch {
            throw NTDFStreamingError.encryptionFailed(error.localizedDescription)
        }
    }

    /// Send raw (unencrypted) video data - for sequence headers
    /// - Parameter frame: The video frame to send without encryption
    public func sendRawVideo(frame: EncodedVideoFrame) async throws {
        guard state == .streaming else {
            throw NTDFStreamingError.notStreaming
        }
        try await rtmpPublisher.send(video: frame)
    }

    /// Send raw (unencrypted) audio data - for sequence headers
    /// - Parameter frame: The audio frame to send without encryption
    public func sendRawAudio(frame: EncodedAudioFrame) async throws {
        guard state == .streaming else {
            throw NTDFStreamingError.notStreaming
        }
        try await rtmpPublisher.send(audio: frame)
    }

    /// Send video sequence header (SPS/PPS) - not encrypted
    public func sendVideoSequenceHeader(formatDescription: CMVideoFormatDescription) async throws {
        guard state == .streaming else {
            throw NTDFStreamingError.notStreaming
        }
        try await rtmpPublisher.sendVideoSequenceHeader(formatDescription: formatDescription)
    }

    /// Send audio sequence header (AudioSpecificConfig) - not encrypted
    public func sendAudioSequenceHeader(asc: Data) async throws {
        guard state == .streaming else {
            throw NTDFStreamingError.notStreaming
        }
        try await rtmpPublisher.sendAudioSequenceHeader(asc: asc)
    }

    /// Magic bytes to identify NTDF header frame: "NTDF" (0x4E544446)
    public static let ntdfHeaderMagic: [UInt8] = [0x4E, 0x54, 0x44, 0x46]

    /// Send NTDF header as a special video data frame that bypasses metadata stripping
    /// Format: [FLV video header 5 bytes][Magic 4 bytes][Header length 2 bytes][Header bytes]
    private func sendNTDFHeaderFrame(_ headerBytes: Data) async throws {
        // Create a special video data tag containing the NTDF header
        // This looks like a video frame but contains our header data
        var payload = Data()

        // FLV video tag header: keyframe (1) + AVC (7) = 0x17
        payload.append(0x17)  // Frame type: keyframe, codec: AVC
        payload.append(0x02)  // AVC packet type: NALU (but we use it for header)
        payload.append(contentsOf: [0x00, 0x00, 0x00])  // Composition time: 0

        // Magic bytes to identify this as NTDF header
        payload.append(contentsOf: Self.ntdfHeaderMagic)

        // Header length (2 bytes big-endian)
        let headerLength = UInt16(headerBytes.count)
        payload.append(UInt8((headerLength >> 8) & 0xFF))
        payload.append(UInt8(headerLength & 0xFF))

        // Header bytes
        payload.append(headerBytes)

        print("📤 [NTDFStreamingManager] Sending NTDF header frame: \(payload.count) bytes (header: \(headerBytes.count) bytes)")

        // Send as video data via RTMP (timestamp 0 since this is initialization data)
        try await rtmpPublisher.sendRawVideoData(payload, timestamp: 0)
    }

    /// Get the NanoTDF header bytes
    public func getHeaderBytes() async throws -> Data {
        guard let collection else {
            throw NTDFStreamingError.notInitialized
        }
        return await collection.getHeaderBytes()
    }

    /// Get base64-encoded header (for ntdf_header metadata field)
    public func getBase64Header() async throws -> String {
        let bytes = try await getHeaderBytes()
        return bytes.base64EncodedString()
    }

    /// Check if IV rotation is needed (approaching 8 million items)
    public var needsRotation: Bool {
        get async {
            guard let collection else { return false }
            return await collection.needsRotation
        }
    }

    /// Rotate to a new collection (new key, IV resets to 1)
    /// Called automatically before each keyframe
    private func rotateCollection() async throws {
        // Clear cache to get fresh KAS key (in case of key rotation)
        await kasService.clearCache()

        // Fetch fresh KAS metadata and create new collection
        let kasMetadata = try await kasService.createKasMetadata()

        // Log KAS public key for debugging
        let kasKeyData = try kasMetadata.getPublicKey()
        let kasKeyHex = kasKeyData.map { String(format: "%02X", $0) }.joined()
        print("🔐 [NTDFStreamingManager] Using KAS public key (\(kasKeyData.count) bytes): \(kasKeyHex)")

        // Create new policy with fresh UUID
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

        // Build new collection (new ephemeral key, new symmetric key)
        collection = try await NanoTDFCollectionBuilder()
            .kasMetadata(kasMetadata)
            .policy(.embeddedPlaintext(policyData))
            .configuration(.default)
            .build()

        // Update cached header and send NTDF header frame
        let headerBytes = await collection!.getHeaderBytes()
        cachedHeaderBytes = headerBytes

        // Log key fingerprint and ephemeral public key
        let symmetricKey = await collection!.getSymmetricKey()
        let keyData = symmetricKey.withUnsafeBytes { Data($0) }
        let keyHash = CryptoKit.SHA256.hash(data: keyData)
        let keyFingerprint = keyHash.prefix(8).map { String(format: "%02X", $0) }.joined()

        // Log ephemeral public key for debugging
        let header = await collection!.header
        let ephemeralKey = header.ephemeralPublicKey
        let ephemeralKeyHex = ephemeralKey.map { String(format: "%02X", $0) }.joined()

        print("🔐 [NTDFStreamingManager] Rotated collection:")
        print("   - Key fingerprint: \(keyFingerprint)")
        print("   - Policy UUID: \(policyUUID.prefix(8))...")
        print("   - Ephemeral pubkey (\(ephemeralKey.count) bytes): \(ephemeralKeyHex)")

        // Send updated metadata with new ntdf_header (for late joiners)
        let base64Header = headerBytes.base64EncodedString()
        try await rtmpPublisher.sendMetadata(
            width: streamWidth,
            height: streamHeight,
            framerate: streamFramerate,
            videoBitrate: streamVideoBitrate,
            audioBitrate: streamAudioBitrate,
            customFields: ["ntdf_header": base64Header]
        )
        print("🔐 [NTDFStreamingManager] Updated metadata with new ntdf_header")

        // Send new NTDF header frame before keyframe (in-band backup)
        try await sendNTDFHeaderFrame(headerBytes)
    }

    /// Get stream statistics from RTMPPublisher
    public var statistics: RTMPPublisher.StreamStatistics {
        get async {
            await rtmpPublisher.statistics
        }
    }

    /// Disconnect and cleanup
    public func disconnect() async {
        print("📡 Disconnecting NTDF stream...")
        await rtmpPublisher.disconnect()
        collection = nil
        cachedHeaderBytes = nil
        state = .idle
        print("✅ NTDF stream disconnected")
    }

    /// Get symmetric key for testing/debugging purposes
    /// WARNING: Only use for testing - exposing the key in production is a security risk
    public func getSymmetricKeyForTesting() async -> SymmetricKey? {
        guard let collection else { return nil }
        return await collection.getSymmetricKey()
    }

    /// Encrypt raw data and return serialized NanoTDF collection item
    /// - Parameter data: Plaintext data to encrypt
    /// - Returns: Serialized encrypted data (IV + length + ciphertext + tag)
    public func encrypt(data: Data) async throws -> Data {
        guard let collection else {
            throw NTDFStreamingError.notInitialized
        }
        let item = try await collection.encryptItem(plaintext: data)
        return await collection.serialize(item: item)
    }
}
