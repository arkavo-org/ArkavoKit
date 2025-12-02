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
/// Combines NanoTDFCollection encryption with RTMPPublisher
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

    /// Current state of the manager
    public var currentState: State { state }

    /// Initialize with KAS URL
    /// - Parameter kasURL: The KAS server URL (e.g., https://100.arkavo.net)
    public init(kasURL: URL) {
        self.kasService = KASPublicKeyService(kasURL: kasURL)
        self.rtmpPublisher = RTMPPublisher()
    }

    /// Initialize encryption: fetch KAS key and create NanoTDF Collection
    /// - Parameter policy: Policy data (empty Data for embedded plaintext)
    public func initialize(policy: Data = Data()) async throws {
        state = .initializing

        do {
            // 1. Fetch KAS public key and create metadata
            print("🔐 Initializing NTDF streaming...")
            let kasMetadata = try await kasService.createKasMetadata()

            // 2. Build NanoTDF Collection
            collection = try await NanoTDFCollectionBuilder()
                .kasMetadata(kasMetadata)
                .policy(.embeddedPlaintext(policy))
                .configuration(.default)
                .build()

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

        state = .streaming
        print("✅ NTDF streaming started with encrypted header")
    }

    /// Encrypt and send video frame
    /// - Parameter frame: The video frame to encrypt and send
    public func sendEncryptedVideo(frame: EncodedVideoFrame) async throws {
        guard let collection, state == .streaming else {
            throw NTDFStreamingError.notStreaming
        }

        do {
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
        state = .idle
        print("✅ NTDF stream disconnected")
    }
}
