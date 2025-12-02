import AVFoundation
import CoreMedia
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
    private let rtmpSubscriber: RTMPSubscriber
    private var decryptor: NanoTDFCollectionDecryptor?
    private var state: State = .idle

    // Video/Audio decoder configuration
    private var videoConfig: FLVDemuxer.AVCDecoderConfig?
    private var audioConfig: FLVDemuxer.AACDecoderConfig?
    private var videoFormatDescription: CMVideoFormatDescription?
    private var audioFormatDescription: CMAudioFormatDescription?

    // Callbacks
    private var onDecryptedFrame: ((DecryptedFrame) async -> Void)?
    private var onStateChange: ((State) async -> Void)?

    public var currentState: State { state }

    // MARK: - Initialization

    /// Initialize with KAS URL for key access
    public init(kasURL: URL) {
        self.kasURL = kasURL
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
            print("📡 Connected, waiting for ntdf_header...")
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
        print("✅ NTDF subscriber disconnected")
    }

    // MARK: - Private Methods

    private func handleMetadata(_ metadata: RTMPSubscriber.StreamMetadata) async {
        print("📥 Received stream metadata")

        // Check for ntdf_header
        guard let ntdfHeaderBase64 = metadata.ntdfHeader else {
            print("⚠️ No ntdf_header in metadata - stream may not be encrypted")
            state = .playing
            await onStateChange?(state)
            return
        }

        // Decode base64 header
        guard let headerBytes = Data(base64Encoded: ntdfHeaderBase64) else {
            print("❌ Failed to decode ntdf_header base64")
            state = .error("Invalid ntdf_header encoding")
            await onStateChange?(state)
            return
        }

        print("🔐 Initializing decryptor with header: \(headerBytes.count) bytes")

        // Initialize decryptor
        do {
            decryptor = try await NanoTDFCollectionDecryptor(
                headerBytes: headerBytes,
                kasURL: kasURL
            )
            state = .playing
            await onStateChange?(state)
            print("✅ Decryptor initialized, ready to decrypt frames")
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

    private func handleVideoFrame(_ frame: RTMPSubscriber.MediaFrame) async {
        // Check if this is a sequence header
        if frame.data.count > 1 {
            let codecId = frame.data[0] & 0x0F
            if codecId == 7, frame.data[1] == 0 {
                // AVC sequence header - not encrypted
                do {
                    videoConfig = try FLVDemuxer.parseAVCSequenceHeader(frame.data)
                    videoFormatDescription = try videoConfig?.createFormatDescription()
                    print("📥 Video sequence header parsed: \(videoConfig?.sps.count ?? 0) SPS, \(videoConfig?.pps.count ?? 0) PPS")
                } catch {
                    print("❌ Failed to parse video sequence header: \(error)")
                }
                return
            }
        }

        // Decrypt if we have a decryptor
        let decryptedData: Data
        if let decryptor {
            do {
                decryptedData = try await decryptor.decrypt(frame.data)
            } catch {
                print("❌ Video decryption failed: \(error)")
                return
            }
        } else {
            // Not encrypted
            decryptedData = frame.data
        }

        // Parse decrypted FLV video frame
        guard let config = videoConfig else {
            print("⚠️ Received video frame before sequence header")
            return
        }

        do {
            let videoFrame = try FLVDemuxer.parseAVCVideoFrame(
                decryptedData,
                naluLengthSize: Int(config.naluLengthSize),
                baseTimestamp: frame.timestamp
            )

            // Create sample buffer if we have format description
            var sampleBuffer: CMSampleBuffer?
            if let formatDesc = videoFormatDescription {
                sampleBuffer = try? FLVDemuxer.createVideoSampleBuffer(
                    frame: videoFrame,
                    formatDescription: formatDesc,
                    naluLengthSize: Int(config.naluLengthSize)
                )
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
            print("❌ Failed to parse video frame: \(error)")
        }
    }

    private func handleAudioFrame(_ frame: RTMPSubscriber.MediaFrame) async {
        // Check if this is a sequence header
        if frame.data.count > 1 {
            let soundFormat = (frame.data[0] >> 4) & 0x0F
            if soundFormat == 10, frame.data[1] == 0 {
                // AAC sequence header - not encrypted
                do {
                    audioConfig = try FLVDemuxer.parseAACSequenceHeader(frame.data)
                    audioFormatDescription = try audioConfig?.createFormatDescription()
                    print("📥 Audio sequence header parsed: \(audioConfig?.sampleRate ?? 0) Hz, \(audioConfig?.channelCount ?? 0) ch")
                } catch {
                    print("❌ Failed to parse audio sequence header: \(error)")
                }
                return
            }
        }

        // Decrypt if we have a decryptor
        let decryptedData: Data
        if let decryptor {
            do {
                decryptedData = try await decryptor.decrypt(frame.data)
            } catch {
                print("❌ Audio decryption failed: \(error)")
                return
            }
        } else {
            decryptedData = frame.data
        }

        // Parse decrypted FLV audio frame
        do {
            let audioFrame = try FLVDemuxer.parseAACAudioFrame(decryptedData, baseTimestamp: frame.timestamp)

            // Create sample buffer if we have format description
            var sampleBuffer: CMSampleBuffer?
            if let formatDesc = audioFormatDescription {
                sampleBuffer = try? FLVDemuxer.createAudioSampleBuffer(
                    frame: audioFrame,
                    formatDescription: formatDesc
                )
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
            print("❌ Failed to parse audio frame: \(error)")
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

// MARK: - NanoTDF Collection Decryptor

/// Decryptor for NanoTDF Collection items
///
/// Uses the collection header and KAS to decrypt individual items.
actor NanoTDFCollectionDecryptor {
    private let header: Data
    private let kasURL: URL
    private var symmetricKey: Data?

    init(headerBytes: Data, kasURL: URL) async throws {
        self.header = headerBytes
        self.kasURL = kasURL

        // Initialize decryption key via KAS rewrap
        try await initializeKey()
    }

    private func initializeKey() async throws {
        // Parse the NanoTDF header to extract key info
        // The header contains the KAS public key and ephemeral key
        // We need to request key rewrap from KAS

        // For now, we'll store the header and use it for each decrypt call
        // In a full implementation, we'd do KAS rewrap here
        print("🔐 NanoTDFCollectionDecryptor initialized (header: \(header.count) bytes)")

        // TODO: Implement KAS rewrap to get symmetric key
        // This requires:
        // 1. Parse header to get ephemeral public key
        // 2. Send rewrap request to KAS with our client key
        // 3. Receive rewrapped key
        // 4. Derive symmetric key from shared secret
    }

    /// Decrypt a single collection item
    func decrypt(_ encryptedData: Data) async throws -> Data {
        // Collection item wire format:
        // - 3 bytes: IV (counter)
        // - 3 bytes: length of ciphertext + tag
        // - N bytes: ciphertext
        // - 8-16 bytes: authentication tag

        guard encryptedData.count >= 6 else {
            throw NTDFSubscriberError.decryptionFailed("Data too short")
        }

        // For now, return data as-is for testing
        // TODO: Implement actual decryption using derived symmetric key
        //
        // let iv = encryptedData.subdata(in: 0..<3)
        // let lengthBytes = encryptedData.subdata(in: 3..<6)
        // let payloadLength = Int(lengthBytes[0]) << 16 | Int(lengthBytes[1]) << 8 | Int(lengthBytes[2])
        // let ciphertext = encryptedData.subdata(in: 6..<encryptedData.count)
        //
        // return try CryptoHelper.decryptAESGCM(
        //     ciphertext: ciphertext,
        //     key: symmetricKey!,
        //     iv: iv.padded(to: 12)
        // )

        print("⚠️ Decryption not yet implemented - returning raw data")
        return encryptedData
    }
}
