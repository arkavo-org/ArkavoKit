import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import OpenTDFKit

/// Error types for NTDF streaming subscriber operations
public enum NTDFSubscriberError: Error, LocalizedError {
    case notInitialized
    case notPlaying
    case missingHeader
    case decryptionFailed(String)
    case connectionFailed(String)
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "NTDFStreamingSubscriber not initialized"
        case .notPlaying:
            return "Not currently playing"
        case .missingHeader:
            return "Missing NanoTDF header from stream metadata"
        case let .decryptionFailed(message):
            return "Decryption failed: \(message)"
        case let .connectionFailed(message):
            return "Connection failed: \(message)"
        case .unsupportedFormat:
            return "Unsupported media format"
        }
    }
}

/// Subscriber for NTDF-encrypted RTMP streams
///
/// Combines RTMPSubscriber with NanoTDF decryption for receiving
/// and decrypting live encrypted video/audio streams.
public actor NTDFStreamingSubscriber {
    // MARK: - Types

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case waitingForHeader
        case playing
        case error(String)
    }

    /// Decrypted media frame ready for rendering
    public struct DecryptedFrame: @unchecked Sendable {
        public enum FrameType: Sendable {
            case video
            case audio
        }

        public let type: FrameType
        public let data: Data
        public let timestamp: UInt32
        public let isKeyframe: Bool
        public let sampleBuffer: CMSampleBuffer?  // Note: CMSampleBuffer is not Sendable but safe here
    }

    // MARK: - Properties

    private let kasURL: URL
    private let ntdfToken: String
    private let rtmpSubscriber: RTMPSubscriber
    private var decryptor: StreamingCollectionDecryptor?
    private var state: State = .idle

    // Video/Audio decoder configuration
    private var videoConfig: FLVDemuxer.AVCDecoderConfig?
    private var audioConfig: FLVDemuxer.AACDecoderConfig?
    private var videoFormatDescription: CMVideoFormatDescription?
    private var audioFormatDescription: CMAudioFormatDescription?

    // Synthetic timestamp generation (rml_rtmp has broken timestamp handling)
    private var videoTimestampMs: UInt32 = 0
    private var audioTimestampMs: UInt32 = 0
    private let videoFrameDurationMs: UInt32 = 33  // ~30fps default
    private let audioFrameDurationMs: UInt32 = 21  // ~48kHz AAC frame duration

    // Callbacks
    private var onDecryptedFrame: ((DecryptedFrame) async -> Void)?
    private var onStateChange: ((State) async -> Void)?

    public var currentState: State { state }

    // MARK: - Initialization

    /// Initialize with KAS URL and NTDF token for key access
    /// - Parameters:
    ///   - kasURL: URL of the KAS server for key rewrap
    ///   - ntdfToken: NTDF token for authentication with KAS
    public init(kasURL: URL, ntdfToken: String) {
        self.kasURL = kasURL
        self.ntdfToken = ntdfToken
        self.rtmpSubscriber = RTMPSubscriber()
    }

    // MARK: - Public Methods

    /// Set callback for decrypted frames
    public func setFrameHandler(_ handler: @escaping (DecryptedFrame) async -> Void) {
        onDecryptedFrame = handler
    }

    /// Set callback for state changes
    public func setStateHandler(_ handler: @escaping (State) async -> Void) {
        onStateChange = handler
    }

    /// Connect to encrypted RTMP stream and start playing
    public func connect(rtmpURL: String, streamName: String) async throws {
        state = .connecting
        await onStateChange?(state)

        // Set up metadata handler to capture ntdf_header
        await rtmpSubscriber.setMetadataHandler { [weak self] metadata in
            await self?.handleMetadata(metadata)
        }

        // Set up frame handler
        await rtmpSubscriber.setFrameHandler { [weak self] frame in
            await self?.handleRawFrame(frame)
        }

        // Connect to RTMP server
        do {
            try await rtmpSubscriber.connect(url: rtmpURL, streamName: streamName)
            state = .waitingForHeader
            await onStateChange?(state)
        } catch {
            state = .error(error.localizedDescription)
            await onStateChange?(state)
            throw NTDFSubscriberError.connectionFailed(error.localizedDescription)
        }
    }

    /// Disconnect from stream
    public func disconnect() async {
        await rtmpSubscriber.disconnect()
        decryptor = nil
        videoConfig = nil
        audioConfig = nil
        videoFormatDescription = nil
        audioFormatDescription = nil
        state = .idle
        await onStateChange?(state)
    }

    // MARK: - Private Methods

    /// Track the header source for debugging
    private var headerSource: String = "none"
    private var metadataHeaderBase64: String?

    /// Buffer for frames that arrive before decryptor is initialized
    private var pendingVideoFrames: [RTMPSubscriber.MediaFrame] = []
    private var pendingAudioFrames: [RTMPSubscriber.MediaFrame] = []
    private let maxPendingFrames = 30  // Don't buffer too many

    private func handleMetadata(_ metadata: RTMPSubscriber.StreamMetadata) async {
        // Check for ntdf_header in metadata (may be stripped by RTMP server)
        guard let ntdfHeaderBase64 = metadata.ntdfHeader else {
            // Don't transition to .playing yet - wait for header frame or timeout
            return
        }

        // Decode base64 header
        guard let headerBytes = Data(base64Encoded: ntdfHeaderBase64) else {
            state = .error("Invalid ntdf_header encoding")
            await onStateChange?(state)
            return
        }

        // Check if this is a new/different header (key rotation)
        let isNewHeader = metadataHeaderBase64 != ntdfHeaderBase64

        // Store for comparison
        metadataHeaderBase64 = ntdfHeaderBase64

        // If decryptor exists and this is a NEW header, add as alternate (key rotation)
        if decryptor != nil && isNewHeader {
            print("🔐 [NTDFSub] Key rotation - adding alternate decryptor")
            do {
                try await decryptor?.addAlternateFromHeader(headerBytes)
            } catch {
                print("🔐 [NTDFSub] ⚠️ Failed to add rotated key: \(error)")
            }
            return
        }

        // Initialize primary decryptor from metadata header
        headerSource = "metadata"
        await initializeDecryptorWithHeader(headerBytes)
    }

    /// Initialize decryptor with NTDF header bytes (from metadata or header frame)
    private func initializeDecryptorWithHeader(_ headerBytes: Data) async {
        // Skip if already initialized
        if decryptor != nil {
            return
        }

        // Initialize decryptor with NTDF token
        do {
            decryptor = try await StreamingCollectionDecryptor(
                headerBytes: headerBytes,
                kasURL: kasURL,
                ntdfToken: ntdfToken
            )
            state = .playing
            await onStateChange?(state)
            print("🔐 [NTDFSub] ✅ Decryptor initialized (source: \(headerSource))")
        } catch {
            print("❌ Failed to create decryptor: \(error)")
            state = .error("Decryptor initialization failed: \(error.localizedDescription)")
            await onStateChange?(state)
        }
    }

    private func handleRawFrame(_ frame: RTMPSubscriber.MediaFrame) async {
        switch frame.type {
        case .video:
            await handleVideoFrame(frame)
        case .audio:
            await handleAudioFrame(frame)
        case .metadata:
            // Already handled via metadata callback
            break
        }
    }

    private var videoFrameCount: UInt64 = 0
    private var audioFrameCount: UInt64 = 0
    private var audioDecryptFails: UInt64 = 0

    /// Magic bytes to identify NTDF header frame: "NTDF" (0x4E544446)
    private static let ntdfHeaderMagic: [UInt8] = [0x4E, 0x54, 0x44, 0x46]

    private func handleVideoFrame(_ frame: RTMPSubscriber.MediaFrame) async {
        videoFrameCount += 1

        // Check if this is a sequence header or NTDF header frame
        if frame.data.count > 1 {
            let codecId = frame.data[0] & 0x0F
            let packetType = frame.data[1]

            // Check for NTDF header frame (special video frame with magic bytes)
            // Format: [17 02 00 00 00][4E 54 44 46][length 2 bytes][header bytes]
            // Note: Check for magic bytes regardless of packetType as RTMP server may modify it
            if codecId == 7, frame.data.count > 11 {
                // Check for NTDF magic bytes at offset 5 (after FLV video header)
                let magicOffset = 5
                if frame.data.count > magicOffset + 4 &&
                    frame.data[magicOffset] == Self.ntdfHeaderMagic[0] &&
                    frame.data[magicOffset + 1] == Self.ntdfHeaderMagic[1] &&
                    frame.data[magicOffset + 2] == Self.ntdfHeaderMagic[2] &&
                    frame.data[magicOffset + 3] == Self.ntdfHeaderMagic[3] {

                    // Extract header length (2 bytes big-endian) at offset 9
                    let headerLength = Int(frame.data[9]) << 8 | Int(frame.data[10])

                    // Extract header bytes
                    if frame.data.count >= 11 + headerLength {
                        let headerBytes = frame.data.subdata(in: 11..<(11 + headerLength))
                        let inbandBase64 = headerBytes.base64EncodedString()

                        // Compare with metadata header and potentially use both
                        var shouldAddMetadataAsAlternate = false
                        if let metaHeader = metadataHeaderBase64, metaHeader != inbandBase64 {
                            shouldAddMetadataAsAlternate = true
                        }

                        // If decryptor already initialized, add this as an alternate key
                        if decryptor != nil {
                            do {
                                try await decryptor?.addAlternateFromHeader(headerBytes)
                            } catch {
                                // Silently ignore - may be duplicate header
                            }
                            return
                        }

                        // Initialize primary decryptor with in-band header
                        headerSource = "inband"
                        await initializeDecryptorWithHeader(headerBytes)

                        // If metadata header differs, also add it as an alternate
                        if shouldAddMetadataAsAlternate, let metaHeader = metadataHeaderBase64,
                           let metaHeaderBytes = Data(base64Encoded: metaHeader) {
                            do {
                                try await decryptor?.addAlternateFromHeader(metaHeaderBytes)
                            } catch {
                                // Silently ignore
                            }
                        }
                    }
                    return
                }
            }

            if codecId == 7, packetType == 0 {
                // AVC sequence header - not encrypted
                do {
                    videoConfig = try FLVDemuxer.parseAVCSequenceHeader(frame.data)
                    videoFormatDescription = try videoConfig?.createFormatDescription()
                    print("🎬 [NTDFSub] Video config: \(videoConfig?.naluLengthSize ?? 0)-byte NAL length")
                } catch {
                    print("🎬 [NTDFSub] ❌ Failed to parse video sequence header: \(error)")
                }
                return
            }
        }

        // FLV video header is 5 bytes: [frameType|codecId][packetType][compositionTime x3]
        // The encrypted payload starts after this header
        let flvHeaderSize = 5
        guard frame.data.count > flvHeaderSize else {
            return
        }

        // Extract FLV header info for later reconstruction
        let flvHeader = frame.data.prefix(flvHeaderSize)
        let encryptedPayload = frame.data.dropFirst(flvHeaderSize)

        // Decrypt if we have a decryptor
        let decryptedData: Data
        if let decryptor {
            do {
                let decryptedPayload = try await decryptor.decrypt(Data(encryptedPayload))
                decryptedData = Data(flvHeader) + decryptedPayload
            } catch {
                // Skip logging - decrypt failures during key rotation are expected
                return
            }
        } else {
            // No decryptor yet - skip until we get NTDF header
            return
        }

        // Parse decrypted FLV video frame
        guard let config = videoConfig else { return }

        do {
            let videoFrame = try FLVDemuxer.parseAVCVideoFrame(
                decryptedData,
                naluLengthSize: Int(config.naluLengthSize),
                baseTimestamp: frame.timestamp
            )

            // Create sample buffer
            var sampleBuffer: CMSampleBuffer?
            if let formatDesc = videoFormatDescription {
                sampleBuffer = try? FLVDemuxer.createVideoSampleBuffer(
                    frame: videoFrame,
                    formatDescription: formatDesc,
                    naluLengthSize: Int(config.naluLengthSize)
                )
            }

            // Log keyframes and periodic status
            if videoFrame.isKeyframe {
                let naluTypes = videoFrame.nalus.compactMap { $0.first.map { $0 & 0x1F } }
                print("🎬 [NTDFSub] 🔑 KEYFRAME #\(videoFrameCount): naluTypes=\(naluTypes), sampleBuffer=\(sampleBuffer != nil)")
            } else if videoFrameCount % 100 == 0 {
                print("🎬 [NTDFSub] Video frame #\(videoFrameCount)")
            }

            // Combine NALUs for callback
            var naluData = Data()
            for nalu in videoFrame.nalus {
                naluData.append(nalu)
            }

            let decryptedFrame = DecryptedFrame(
                type: .video,
                data: naluData,
                timestamp: frame.timestamp,
                isKeyframe: videoFrame.isKeyframe,
                sampleBuffer: sampleBuffer
            )

            await onDecryptedFrame?(decryptedFrame)
        } catch {
            // Skip logging - parse failures are rare
        }
    }

    private func handleAudioFrame(_ frame: RTMPSubscriber.MediaFrame) async {
        audioFrameCount += 1

        // Check if this is a sequence header
        if frame.data.count > 1 {
            let soundFormat = (frame.data[0] >> 4) & 0x0F
            if soundFormat == 10, frame.data[1] == 0 {
                // AAC sequence header - not encrypted
                do {
                    audioConfig = try FLVDemuxer.parseAACSequenceHeader(frame.data)
                    audioFormatDescription = try audioConfig?.createFormatDescription()
                    print("🔊 [NTDFSub] Audio config: \(audioConfig?.sampleRate ?? 0)Hz, \(audioConfig?.channelCount ?? 0)ch")
                } catch {
                    print("🔊 [NTDFSub] ❌ Failed to parse audio sequence header: \(error)")
                }
                return
            }
        }

        // FLV audio header is 2 bytes: [soundFormat|sampleRate|sampleSize|channels][aacPacketType]
        // The encrypted payload starts after this header
        let flvAudioHeaderSize = 2
        guard frame.data.count > flvAudioHeaderSize else {
            return
        }

        // Extract FLV header info for later reconstruction
        let flvHeader = frame.data.prefix(flvAudioHeaderSize)
        let encryptedPayload = frame.data.dropFirst(flvAudioHeaderSize)

        // Decrypt if we have a decryptor
        let decryptedData: Data
        if let decryptor {
            do {
                // Decrypt only the payload (after FLV header)
                let decryptedPayload = try await decryptor.decrypt(Data(encryptedPayload))
                // Reconstruct FLV frame with decrypted payload
                decryptedData = Data(flvHeader) + decryptedPayload
            } catch {
                audioDecryptFails += 1
                if audioDecryptFails <= 5 || audioDecryptFails % 100 == 0 {
                    print("🔊 [NTDFSub] ⚠️ Audio decrypt fail #\(audioDecryptFails) (total frames: \(audioFrameCount))")
                }
                return
            }
        } else {
            return  // No decryptor yet
        }

        // Parse decrypted FLV audio frame
        do {
            let audioFrame = try FLVDemuxer.parseAACAudioFrame(decryptedData, baseTimestamp: frame.timestamp)

            // Create sample buffer if we have format description
            var sampleBuffer: CMSampleBuffer?
            if let formatDesc = audioFormatDescription, let config = audioConfig {
                sampleBuffer = try? FLVDemuxer.createAudioSampleBuffer(
                    frame: audioFrame,
                    formatDescription: formatDesc,
                    sampleRate: config.sampleRate
                )
            }

            // Log audio stats periodically
            if audioFrameCount % 500 == 0 {
                let failRate = audioDecryptFails > 0 ? Double(audioDecryptFails) / Double(audioFrameCount) * 100 : 0
                print("🔊 [NTDFSub] Audio #\(audioFrameCount): \(audioDecryptFails) fails (\(String(format: "%.1f", failRate))%)")
            }

            let decryptedFrame = DecryptedFrame(
                type: .audio,
                data: audioFrame.data,
                timestamp: frame.timestamp,
                isKeyframe: false,
                sampleBuffer: sampleBuffer
            )

            await onDecryptedFrame?(decryptedFrame)
        } catch {
            // Skip frames that fail to parse
        }
    }

    /// Get video format description (available after receiving sequence header)
    public var videoFormat: CMVideoFormatDescription? {
        videoFormatDescription
    }

    /// Get audio format description (available after receiving sequence header)
    public var audioFormat: CMAudioFormatDescription? {
        audioFormatDescription
    }
}

// MARK: - Streaming Collection Decryptor

/// Decryptor for NanoTDF Collection items in streaming context
///
/// Wraps OpenTDFKit's NanoTDFCollectionDecryptor with KAS rewrap integration.
/// Parses the collection header, performs KAS rewrap to obtain the symmetric key,
/// and provides per-frame decryption using the shared key.
actor StreamingCollectionDecryptor {
    /// The parsed NanoTDF header
    private let header: Header

    /// The raw header bytes (needed for KAS rewrap request)
    private let headerBytes: Data

    /// KAS URL for key rewrap
    private let kasURL: URL

    /// NTDF token for KAS authentication
    private let ntdfToken: String

    /// The underlying OpenTDFKit decryptor (initialized after KAS rewrap)
    private var decryptor: OpenTDFKit.NanoTDFCollectionDecryptor?

    /// Additional decryptors for key rotation scenarios (n-1, n+1 keys)
    private var alternateDecryptors: [OpenTDFKit.NanoTDFCollectionDecryptor] = []

    /// Cipher configuration from header
    private let cipher: Cipher

    /// Tag size for parsing encrypted items
    private let tagSize: Int

    /// Counter for debugging decryption attempts
    private var itemsDecrypted: Int = 0

    /// Track which decryptor succeeded for logging
    private var lastSuccessfulDecryptorIndex: Int = -1  // -1 = primary, 0+ = alternate

    /// Initialize with header bytes, KAS URL, and NTDF token
    /// - Parameters:
    ///   - headerBytes: Raw NanoTDF collection header bytes from stream metadata
    ///   - kasURL: URL of the KAS server for key rewrap
    ///   - ntdfToken: NTDF token for KAS authentication
    /// - Throws: If header parsing fails or KAS rewrap fails
    init(headerBytes: Data, kasURL: URL, ntdfToken: String) async throws {
        self.headerBytes = headerBytes
        self.kasURL = kasURL
        self.ntdfToken = ntdfToken

        // Parse the NanoTDF header using BinaryParser
        let parser = BinaryParser(data: headerBytes)
        do {
            self.header = try parser.parseHeader()
        } catch {
            throw NTDFSubscriberError.decryptionFailed("Failed to parse NanoTDF header: \(error)")
        }

        // Get cipher and tag size from header
        self.cipher = header.payloadSignatureConfig.payloadCipher ?? .aes256GCM128
        self.tagSize = cipher.tagSize

        // Perform KAS rewrap to get symmetric key
        try await performKASRewrap()
    }

    /// Perform KAS rewrap to obtain the symmetric key for decryption
    /// Uses KASRewrapClient from OpenTDFKit for proper PEM/JWT handling
    private func performKASRewrap() async throws {
        // Generate client ephemeral key pair (matching OpenTDFKit CLI pattern)
        let privateKey = P256.KeyAgreement.PrivateKey()
        let clientKeyPair = EphemeralKeyPair(
            privateKey: privateKey.rawRepresentation,
            publicKey: privateKey.publicKey.compressedRepresentation,
            curve: .secp256r1
        )

        // Convert to PEM format for KAS request (matching OpenTDFKit CLI)
        let publicKeyPEM = try convertToSPKIPEM(compressedKey: clientKeyPair.publicKey)
        let pemKeyPair = EphemeralKeyPair(
            privateKey: clientKeyPair.privateKey,
            publicKey: publicKeyPEM.data(using: .utf8)!,
            curve: .secp256r1
        )

        do {
            // Use OpenTDFKit's KASRewrapClient for proper request/response handling
            let kasRewrapURL: URL
            if kasURL.path.hasSuffix("/kas") || kasURL.path.contains("/kas/") {
                kasRewrapURL = kasURL
            } else {
                kasRewrapURL = kasURL.appendingPathComponent("kas")
            }
            let kasClient = KASRewrapClient(kasURL: kasRewrapURL, oauthToken: ntdfToken)

            let (wrappedKey, sessionPublicKey) = try await kasClient.rewrapNanoTDF(
                header: headerBytes,
                parsedHeader: header,
                clientKeyPair: pemKeyPair
            )

            // Unwrap the key using OpenTDFKit's unwrapKey (handles HKDF salt correctly)
            let symmetricKey = try KASRewrapClient.unwrapKey(
                wrappedKey: wrappedKey,
                sessionPublicKey: sessionPublicKey,
                clientPrivateKey: clientKeyPair.privateKey
            )

            // Create the OpenTDFKit decryptor with the unwrapped key
            self.decryptor = NanoTDFCollectionDecryptor.withUnwrappedKey(
                symmetricKey: symmetricKey,
                cipher: cipher
            )

            print("🔐 [NTDFSub] ✅ KAS rewrap complete, decryptor ready")

        } catch let error as KASRewrapError {
            print("❌ KAS rewrap failed: \(error.description)")
            throw NTDFSubscriberError.decryptionFailed("KAS rewrap failed: \(error.description)")
        } catch {
            print("❌ KAS rewrap failed: \(error)")
            throw NTDFSubscriberError.decryptionFailed("KAS rewrap failed: \(error.localizedDescription)")
        }
    }

    /// Decrypt a single encrypted collection item
    /// - Parameter encryptedData: The encrypted frame data in collection wire format
    /// - Returns: Decrypted plaintext data
    /// - Throws: If decryption fails
    func decrypt(_ encryptedData: Data) async throws -> Data {
        guard let decryptor else {
            throw NTDFSubscriberError.decryptionFailed("Decryptor not initialized")
        }

        // Parse collection item wire format:
        // - 3 bytes: IV counter (big-endian)
        // - 3 bytes: length of ciphertext + tag (big-endian)
        // - N bytes: ciphertext + tag

        guard encryptedData.count >= 6 else {
            throw NTDFSubscriberError.decryptionFailed("Encrypted data too short: \(encryptedData.count) bytes")
        }

        // Parse IV counter (3 bytes, big-endian)
        let ivCounter = UInt32(encryptedData[0]) << 16 |
                        UInt32(encryptedData[1]) << 8 |
                        UInt32(encryptedData[2])

        // Parse payload length (3 bytes, big-endian)
        let payloadLength = Int(encryptedData[3]) << 16 |
                           Int(encryptedData[4]) << 8 |
                           Int(encryptedData[5])

        // Validate we have enough data
        let expectedTotal = 6 + payloadLength
        guard encryptedData.count >= expectedTotal else {
            throw NTDFSubscriberError.decryptionFailed(
                "Incomplete encrypted data: have \(encryptedData.count), need \(expectedTotal)"
            )
        }

        // Extract ciphertext + tag
        let ciphertextWithTag = encryptedData.subdata(in: 6..<(6 + payloadLength))
        itemsDecrypted += 1

        // Create CollectionItem for decryption
        let item = CollectionItem(
            ivCounter: ivCounter,
            ciphertextWithTag: ciphertextWithTag,
            tagSize: tagSize
        )

        // Try primary decryptor first
        do {
            let result = try await decryptor.decryptItem(item)
            lastSuccessfulDecryptorIndex = -1
            return result
        } catch {
            // Primary decryptor failed, try alternates
            for (index, altDecryptor) in alternateDecryptors.enumerated() {
                do {
                    let result = try await altDecryptor.decryptItem(item)
                    lastSuccessfulDecryptorIndex = index
                    return result
                } catch {
                    continue
                }
            }

            // All decryptors failed
            throw NTDFSubscriberError.decryptionFailed("Decryption failed with all \(1 + alternateDecryptors.count) keys: \(error)")
        }
    }

    /// Add an alternate decryptor (for key rotation scenarios)
    func addAlternateDecryptor(_ decryptor: OpenTDFKit.NanoTDFCollectionDecryptor) {
        alternateDecryptors.append(decryptor)
    }

    /// Add alternate decryptor from a new header (when receiving updated NTDF header frames)
    func addAlternateFromHeader(_ newHeaderBytes: Data) async throws {

        // Generate new client ephemeral key pair
        let privateKey = P256.KeyAgreement.PrivateKey()
        let clientKeyPair = EphemeralKeyPair(
            privateKey: privateKey.rawRepresentation,
            publicKey: privateKey.publicKey.compressedRepresentation,
            curve: .secp256r1
        )

        let publicKeyPEM = try convertToSPKIPEM(compressedKey: clientKeyPair.publicKey)
        let pemKeyPair = EphemeralKeyPair(
            privateKey: clientKeyPair.privateKey,
            publicKey: publicKeyPEM.data(using: .utf8)!,
            curve: .secp256r1
        )

        // Parse the new header
        let parser = BinaryParser(data: newHeaderBytes)
        let newHeader = try parser.parseHeader()

        // Perform KAS rewrap for the new header
        // Note: KASRewrapClient appends "v2/rewrap", so we need "/kas" in the path
        // Only append "/kas" if it's not already there
        let kasRewrapURL: URL
        if kasURL.path.hasSuffix("/kas") || kasURL.path.contains("/kas/") {
            kasRewrapURL = kasURL
        } else {
            kasRewrapURL = kasURL.appendingPathComponent("kas")
        }
        let kasClient = KASRewrapClient(kasURL: kasRewrapURL, oauthToken: ntdfToken)
        let (wrappedKey, sessionPublicKey) = try await kasClient.rewrapNanoTDF(
            header: newHeaderBytes,
            parsedHeader: newHeader,
            clientKeyPair: pemKeyPair
        )

        let symmetricKey = try KASRewrapClient.unwrapKey(
            wrappedKey: wrappedKey,
            sessionPublicKey: sessionPublicKey,
            clientPrivateKey: clientKeyPair.privateKey
        )

        let altDecryptor = NanoTDFCollectionDecryptor.withUnwrappedKey(
            symmetricKey: symmetricKey,
            cipher: cipher
        )

        alternateDecryptors.append(altDecryptor)
    }

    /// Convert compressed P256 public key to PEM format
    private func convertToSPKIPEM(compressedKey: Data) throws -> String {
        guard compressedKey.count == 33 else {
            throw NTDFSubscriberError.decryptionFailed("Invalid compressed key size: \(compressedKey.count)")
        }

        let tempKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: compressedKey)
        let sec1Bytes = tempKey.x963Representation
        let base64String = sec1Bytes.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PUBLIC KEY-----\n\(base64String)-----END PUBLIC KEY-----"
    }
}
