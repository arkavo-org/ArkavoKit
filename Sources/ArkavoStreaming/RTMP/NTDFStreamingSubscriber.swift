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
    private var decryptorInitTask: Task<StreamingCollectionDecryptor, Error>?
    private var connectionGeneration: UInt64 = 0
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
        // Clean up any prior session state before connecting
        connectionGeneration &+= 1
        decryptorInitTask?.cancel()
        decryptorInitTask = nil
        decryptor = nil
        metadataHeaderBase64 = nil
        headerSource = "none"
        videoConfig = nil
        audioConfig = nil
        videoFormatDescription = nil
        audioFormatDescription = nil
        videoFrameCount = 0
        audioFrameCount = 0
        audioDecryptFails = 0
        videoTimestampMs = 0
        audioTimestampMs = 0
        pendingVideoFrames.removeAll()
        pendingAudioFrames.removeAll()

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
        connectionGeneration &+= 1
        decryptorInitTask?.cancel()
        decryptorInitTask = nil
        await rtmpSubscriber.disconnect()
        decryptor = nil
        videoConfig = nil
        audioConfig = nil
        videoFormatDescription = nil
        audioFormatDescription = nil
        metadataHeaderBase64 = nil
        headerSource = "none"
        videoFrameCount = 0
        audioFrameCount = 0
        audioDecryptFails = 0
        videoTimestampMs = 0
        audioTimestampMs = 0
        pendingVideoFrames.removeAll()
        pendingAudioFrames.removeAll()
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

        // If decryptor exists and this is a NEW header, rotate (deduplicated inside decryptor)
        if decryptor != nil {
            if isNewHeader {
                print("🔐 [NTDFSub] Key rotation - updating decryptor")
                do {
                    try await decryptor?.addAlternateFromHeader(headerBytes)
                } catch {
                    print("🔐 [NTDFSub] ⚠️ Failed to add rotated key: \(error)")
                }
            }
            return
        }

        // Initialize primary decryptor from metadata header (coalesced across concurrent callers)
        headerSource = "metadata"
        await initializeDecryptorWithHeader(headerBytes)
    }

    /// Initialize decryptor with NTDF header bytes (from metadata or header frame).
    /// Coalesces concurrent setup calls under actor reentrancy so KAS is only called once
    /// for the initial header, and discards stale completions after `disconnect()`.
    private func initializeDecryptorWithHeader(_ headerBytes: Data) async {
        // If already initialized, register header as rotation (deduplicated inside decryptor)
        if let existing = decryptor {
            try? await existing.addAlternateFromHeader(headerBytes)
            return
        }

        // If another task is already initializing the decryptor, coalesce on it
        if let inFlight = decryptorInitTask {
            if let readyDecryptor = try? await inFlight.value {
                try? await readyDecryptor.addAlternateFromHeader(headerBytes)
            }
            return
        }

        let generation = connectionGeneration
        let kasURL = self.kasURL
        let ntdfToken = self.ntdfToken
        let task = Task {
            try await StreamingCollectionDecryptor(
                headerBytes: headerBytes,
                kasURL: kasURL,
                ntdfToken: ntdfToken
            )
        }
        decryptorInitTask = task

        do {
            let created = try await task.value
            guard generation == connectionGeneration else { return }
            decryptorInitTask = nil
            decryptor = created
            state = .playing
            await onStateChange?(state)
            print("🔐 [NTDFSub] ✅ Decryptor initialized (source: \(headerSource))")
        } catch {
            guard generation == connectionGeneration else { return }
            decryptorInitTask = nil
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
        let data = frame.data.startIndex == 0 ? frame.data : Data(frame.data)

        // Check if this is a sequence header or NTDF header frame
        if data.count > 1 {
            let codecId = data[0] & 0x0F
            let packetType = data[1]

            // Check for NTDF header frame (special video frame with magic bytes)
            // Format: [17 02 00 00 00][4E 54 44 46][length 2 bytes][header bytes]
            // Note: Check for magic bytes regardless of packetType as RTMP server may modify it
            if codecId == 7, data.count > 11 {
                // Check for NTDF magic bytes at offset 5 (after FLV video header)
                let magicOffset = 5
                if data.count > magicOffset + 4 &&
                    data[magicOffset] == Self.ntdfHeaderMagic[0] &&
                    data[magicOffset + 1] == Self.ntdfHeaderMagic[1] &&
                    data[magicOffset + 2] == Self.ntdfHeaderMagic[2] &&
                    data[magicOffset + 3] == Self.ntdfHeaderMagic[3] {

                    // Extract header length (2 bytes big-endian) at offset 9
                    let headerLength = Int(data[9]) << 8 | Int(data[10])

                    // Extract header bytes
                    if data.count >= 11 + headerLength {
                        let headerBytes = data.subdata(in: 11..<(11 + headerLength))
                        let inbandBase64 = headerBytes.base64EncodedString()

                        // Compare with metadata header and potentially use both
                        var shouldAddMetadataAsAlternate = false
                        if let metaHeader = metadataHeaderBase64, metaHeader != inbandBase64 {
                            shouldAddMetadataAsAlternate = true
                        }

                        // If decryptor already initialized, add/promote this key (deduplicated)
                        if decryptor != nil {
                            do {
                                try await decryptor?.addAlternateFromHeader(headerBytes)
                            } catch {
                                // Ignore errors on duplicate/invalid rotated header frames
                            }
                            return
                        }

                        // Initialize primary decryptor with in-band header (coalesced)
                        headerSource = "inband"
                        await initializeDecryptorWithHeader(headerBytes)

                        // If metadata header differs, also add it as an alternate
                        if shouldAddMetadataAsAlternate, let metaHeader = metadataHeaderBase64,
                           let metaHeaderBytes = Data(base64Encoded: metaHeader) {
                            do {
                                try await decryptor?.addAlternateFromHeader(metaHeaderBytes)
                            } catch {
                                // Ignore
                            }
                        }
                    }
                    return
                }
            }

            if codecId == 7, packetType == 0 {
                // AVC sequence header - not encrypted
                do {
                    videoConfig = try FLVDemuxer.parseAVCSequenceHeader(data)
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
        guard data.count > flvHeaderSize else {
            return
        }

        // Extract FLV header info for later reconstruction
        let flvHeader = data.prefix(flvHeaderSize)
        let encryptedPayload = data.dropFirst(flvHeaderSize)

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
        let data = frame.data.startIndex == 0 ? frame.data : Data(frame.data)

        // Check if this is a sequence header
        if data.count > 1 {
            let soundFormat = (data[0] >> 4) & 0x0F
            if soundFormat == 10, data[1] == 0 {
                // AAC sequence header - not encrypted
                do {
                    audioConfig = try FLVDemuxer.parseAACSequenceHeader(data)
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
        guard data.count > flvAudioHeaderSize else {
            return
        }

        // Extract FLV header info for later reconstruction
        let flvHeader = data.prefix(flvAudioHeaderSize)
        let encryptedPayload = data.dropFirst(flvAudioHeaderSize)

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
/// Maintains a bounded newest-first ring/LRU cache of rotated keys deduplicated
/// by header SHA-256 digest so steady-state decryption stays O(1) and memory/KAS
/// requests remain bounded.
actor StreamingCollectionDecryptor {
    struct DecryptorEntry {
        let headerDigest: Data
        let decryptor: OpenTDFKit.NanoTDFCollectionDecryptor
        let cipher: Cipher
        let tagSize: Int
    }

    /// Maximum number of rotated collection decryptors retained in memory.
    static let maxCachedDecryptors = 8

    /// KAS URL for key rewrap
    private let kasURL: URL

    /// NTDF token for KAS authentication
    private let ntdfToken: String

    /// Bounded newest-first list of decryptors (index 0 is the active/newest primary key).
    private var entries: [DecryptorEntry] = []

    /// Digests of headers currently undergoing KAS rewrap to deduplicate concurrent arrivals.
    private var inFlightHeaderDigests: Set<Data> = []

    /// Counter for debugging decryption attempts
    private var itemsDecrypted: Int = 0

    /// Number of currently cached decryptors (for testing/diagnostics).
    var cachedDecryptorCount: Int {
        entries.count
    }

    /// Initialize with header bytes, KAS URL, and NTDF token
    /// - Parameters:
    ///   - headerBytes: Raw NanoTDF collection header bytes from stream metadata
    ///   - kasURL: URL of the KAS server for key rewrap
    ///   - ntdfToken: NTDF token for KAS authentication
    /// - Throws: If header parsing fails or KAS rewrap fails
    init(headerBytes: Data, kasURL: URL, ntdfToken: String) async throws {
        self.kasURL = kasURL
        self.ntdfToken = ntdfToken

        try await addAlternateFromHeader(headerBytes)
    }

    /// Test-only initializer bypassing KAS network calls with pre-unwrapped keys.
    init(
        initialDecryptor: OpenTDFKit.NanoTDFCollectionDecryptor,
        cipher: Cipher = .aes256GCM128,
        headerDigest: Data = Data(),
        kasURL: URL = URL(string: "https://localhost")!,
        ntdfToken: String = ""
    ) {
        self.kasURL = kasURL
        self.ntdfToken = ntdfToken
        let entry = DecryptorEntry(
            headerDigest: headerDigest,
            decryptor: initialDecryptor,
            cipher: cipher,
            tagSize: cipher.tagSize
        )
        self.entries = [entry]
    }

    /// Decrypt a single encrypted collection item
    /// - Parameter encryptedData: The encrypted frame data in collection wire format
    /// - Returns: Decrypted plaintext data
    /// - Throws: If decryption fails
    func decrypt(_ encryptedData: Data) async throws -> Data {
        guard !entries.isEmpty else {
            throw NTDFSubscriberError.decryptionFailed("Decryptor not initialized")
        }

        // Normalize Data slice so indexing starts at 0
        let data = encryptedData.startIndex == 0 ? encryptedData : Data(encryptedData)

        // Parse collection item wire format:
        // - 3 bytes: IV counter (big-endian)
        // - 3 bytes: length of ciphertext + tag (big-endian)
        // - N bytes: ciphertext + tag
        guard data.count >= 6 else {
            throw NTDFSubscriberError.decryptionFailed("Encrypted data too short: \(data.count) bytes")
        }

        // Parse IV counter (3 bytes, big-endian)
        let ivCounter = UInt32(data[0]) << 16 |
                        UInt32(data[1]) << 8 |
                        UInt32(data[2])

        // Parse payload length (3 bytes, big-endian)
        let payloadLength = Int(data[3]) << 16 |
                            Int(data[4]) << 8 |
                            Int(data[5])

        // Validate we have enough data (use subtraction to avoid overflow)
        guard payloadLength <= data.count - 6 else {
            throw NTDFSubscriberError.decryptionFailed(
                "Incomplete encrypted data: have \(data.count), need \(6 + payloadLength)"
            )
        }

        // Extract ciphertext + tag
        let ciphertextWithTag = data.subdata(in: 6..<(6 + payloadLength))
        itemsDecrypted += 1

        // Try entries newest-first (index 0 is the current primary key -> O(1) steady-state)
        var lastError: Error?
        var triedAny = false
        for entry in entries {
            // Validate payloadLength >= entry.tagSize before constructing CollectionItem
            // (OpenTDFKit.CollectionItem preconditions tagSize <= ciphertextWithTag.count).
            guard payloadLength >= entry.tagSize else {
                continue
            }
            triedAny = true
            let item = CollectionItem(
                ivCounter: ivCounter,
                ciphertextWithTag: ciphertextWithTag,
                tagSize: entry.tagSize
            )
            do {
                return try await entry.decryptor.decryptItem(item)
            } catch {
                lastError = error
            }
        }

        if !triedAny {
            throw NTDFSubscriberError.decryptionFailed(
                "Encrypted payload too short for authentication tag: \(payloadLength) bytes"
            )
        }

        throw NTDFSubscriberError.decryptionFailed(
            "Decryption failed with all \(entries.count) keys: \(lastError?.localizedDescription ?? "unknown error")"
        )
    }

    /// Add and promote a decryptor (for key rotation scenarios), maintaining bounded capacity.
    func addAlternateDecryptor(
        _ decryptor: OpenTDFKit.NanoTDFCollectionDecryptor,
        cipher: Cipher = .aes256GCM128,
        headerDigest: Data? = nil
    ) {
        let digest = headerDigest ?? Data(UUID().uuidString.utf8)
        insertEntry(
            DecryptorEntry(
                headerDigest: digest,
                decryptor: decryptor,
                cipher: cipher,
                tagSize: cipher.tagSize
            )
        )
    }

    /// Add and promote a decryptor from a new header (when receiving updated NTDF header frames).
    /// Deduplicates identical headers (both cached and in-flight) by SHA-256 digest.
    func addAlternateFromHeader(_ newHeaderBytes: Data) async throws {
        let digest = Data(SHA256.hash(data: newHeaderBytes))

        // Skip if this header is already cached or currently being rewrapped
        if entries.contains(where: { $0.headerDigest == digest }) {
            return
        }
        if inFlightHeaderDigests.contains(digest) {
            return
        }
        inFlightHeaderDigests.insert(digest)
        defer { inFlightHeaderDigests.remove(digest) }

        // Parse the new header
        let parser = BinaryParser(data: newHeaderBytes)
        let newHeader: Header
        do {
            newHeader = try parser.parseHeader()
        } catch {
            throw NTDFSubscriberError.decryptionFailed("Failed to parse NanoTDF header: \(error)")
        }

        let newCipher = newHeader.payloadSignatureConfig.payloadCipher ?? .aes256GCM128

        // Generate client ephemeral key pair with 33-byte compressed public key
        // (OpenTDFKit KASRewrapClient.rewrapNanoTDF converts the 33-byte compressed key to SPKI PEM internally).
        let privateKey = P256.KeyAgreement.PrivateKey()
        let clientKeyPair = EphemeralKeyPair(
            privateKey: privateKey.rawRepresentation,
            publicKey: privateKey.publicKey.compressedRepresentation,
            curve: .secp256r1
        )

        do {
            let kasClient = try KASRewrapClientFactory.make(kasURL: kasURL, oauthToken: ntdfToken)
            let (wrappedKey, sessionPublicKey) = try await kasClient.rewrapNanoTDF(
                header: newHeaderBytes,
                parsedHeader: newHeader,
                clientKeyPair: clientKeyPair
            )

            let symmetricKey = try KASRewrapClient.unwrapKey(
                wrappedKey: wrappedKey,
                sessionPublicKey: sessionPublicKey,
                clientPrivateKey: clientKeyPair.privateKey
            )

            let newDecryptor = NanoTDFCollectionDecryptor.withUnwrappedKey(
                symmetricKey: symmetricKey,
                cipher: newCipher
            )

            insertEntry(
                DecryptorEntry(
                    headerDigest: digest,
                    decryptor: newDecryptor,
                    cipher: newCipher,
                    tagSize: newCipher.tagSize
                )
            )
            print("🔐 [NTDFSub] ✅ KAS rewrap complete, decryptor ready (cached keys: \(entries.count))")
        } catch let error as KASRewrapError {
            print("❌ KAS rewrap failed: \(error.description)")
            throw NTDFSubscriberError.decryptionFailed("KAS rewrap failed: \(error.description)")
        } catch {
            print("❌ KAS rewrap failed: \(error)")
            throw NTDFSubscriberError.decryptionFailed("KAS rewrap failed: \(error.localizedDescription)")
        }
    }

    private func insertEntry(_ entry: DecryptorEntry) {
        if let existingIndex = entries.firstIndex(where: { $0.headerDigest == entry.headerDigest }) {
            entries.remove(at: existingIndex)
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxCachedDecryptors {
            entries.removeLast(entries.count - Self.maxCachedDecryptors)
        }
    }

    /// Convert a 33-byte compressed P-256 public key to standard RFC 7468 SPKI PEM format.
    static func convertToSPKIPEM(compressedKey: Data) throws -> String {
        guard compressedKey.count == 33 else {
            throw NTDFSubscriberError.decryptionFailed("Invalid compressed key size: \(compressedKey.count)")
        }

        let publicKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: compressedKey)
        let derBytes = publicKey.derRepresentation
        let base64String = derBytes.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PUBLIC KEY-----\n\(base64String)\n-----END PUBLIC KEY-----"
    }
}
