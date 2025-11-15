import Foundation
import Network
@preconcurrency import AVFoundation

/// RTMP publisher for live streaming video/audio
///
/// Implements RTMP protocol for publishing live streams to servers like Twitch, YouTube, etc.
/// Supports FLV container format with H.264 video and AAC audio.
public actor RTMPPublisher {

    // MARK: - Types

    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case publishing
        case error(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.connected, .connected),
                 (.publishing, .publishing):
                return true
            case (.error(let lhsMsg), .error(let rhsMsg)):
                return lhsMsg == rhsMsg
            default:
                return false
            }
        }
    }

    public enum RTMPError: Error, LocalizedError {
        case invalidURL
        case connectionFailed(String)
        case handshakeFailed
        case publishFailed(String)
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid RTMP URL"
            case .connectionFailed(let reason):
                return "Connection failed: \(reason)"
            case .handshakeFailed:
                return "RTMP handshake failed"
            case .publishFailed(let reason):
                return "Publish failed: \(reason)"
            case .notConnected:
                return "Not connected to RTMP server"
            }
        }
    }

    public struct Destination: Sendable {
        public let url: String  // rtmp://server.com/app/streamkey
        public let platform: String  // "twitch", "youtube", "custom"

        public init(url: String, platform: String) {
            self.url = url
            self.platform = platform
        }
    }

    // MARK: - Properties

    private var connection: NWConnection?
    private var state: State = .disconnected
    private var isHandshakeComplete = false
    private var connectionContinuationResumed = false

    // Stream configuration
    private var destination: Destination?
    private var streamKey: String?

    // Statistics
    private var bytesSent: UInt64 = 0
    private var framesSent: UInt64 = 0
    private var startTime: Date?

    public var currentState: State {
        state
    }

    public var statistics: StreamStatistics {
        StreamStatistics(
            bytesSent: bytesSent,
            framesSent: framesSent,
            duration: startTime.map { Date().timeIntervalSince($0) } ?? 0,
            bitrate: calculateBitrate()
        )
    }

    public struct StreamStatistics: Sendable {
        public let bytesSent: UInt64
        public let framesSent: UInt64
        public let duration: TimeInterval
        public let bitrate: Double  // bits per second
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// Connect to RTMP server and start publishing
    public func connect(to destination: Destination, streamKey: String) async throws {
        self.destination = destination
        self.streamKey = streamKey

        // Parse RTMP URL
        guard let url = parseRTMPURL(destination.url) else {
            throw RTMPError.invalidURL
        }

        print("📡 Connecting to RTMP: \(url.host):\(url.port)")

        // Create TCP connection
        let host = NWEndpoint.Host(url.host)
        let port = NWEndpoint.Port(integerLiteral: UInt16(url.port))

        connection = NWConnection(host: host, port: port, using: .tcp)

        state = .connecting
        connectionContinuationResumed = false

        // Start connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection?.stateUpdateHandler = { [weak self] newState in
                Task { [weak self] in
                    await self?.handleConnectionState(newState, continuation: continuation)
                }
            }

            connection?.start(queue: .global(qos: .userInitiated))
        }

        // Perform RTMP handshake
        try await performHandshake()

        // Connect to application
        try await connectToApp(url.app, streamKey: streamKey)

        state = .publishing
        startTime = Date()

        print("✅ RTMP publishing started")
    }

    /// Publish video frame
    public func publishVideo(buffer: CMSampleBuffer, timestamp: CMTime) async throws {
        guard state == .publishing else {
            throw RTMPError.notConnected
        }

        // Check if connection is still valid
        guard let connection = connection, connection.state == .ready else {
            throw RTMPError.connectionFailed("Connection not ready")
        }

        // Convert to FLV video packet
        guard let flvPacket = try? createFLVVideoPacket(from: buffer, timestamp: timestamp) else {
            print("⚠️ Failed to create FLV video packet")
            return
        }

        try await sendData(flvPacket)
        framesSent += 1
    }

    /// Publish audio sample
    public func publishAudio(buffer: CMSampleBuffer, timestamp: CMTime) async throws {
        guard state == .publishing else {
            throw RTMPError.notConnected
        }

        // Check if connection is still valid
        guard let connection = connection, connection.state == .ready else {
            throw RTMPError.connectionFailed("Connection not ready")
        }

        // Convert to FLV audio packet
        guard let flvPacket = try? createFLVAudioPacket(from: buffer, timestamp: timestamp) else {
            print("⚠️ Failed to create FLV audio packet")
            return
        }

        try await sendData(flvPacket)
    }

    /// Disconnect from server
    public func disconnect() async {
        print("📡 Disconnecting RTMP...")
        connection?.cancel()
        connection = nil
        state = .disconnected
        isHandshakeComplete = false
        bytesSent = 0
        framesSent = 0
        startTime = nil
    }

    // MARK: - Private Methods

    private struct RTMPURL {
        let host: String
        let port: Int
        let app: String
    }

    private func parseRTMPURL(_ urlString: String) -> RTMPURL? {
        // Parse rtmp://server:port/app/streamkey
        guard let url = URL(string: urlString) else { return nil }
        guard url.scheme == "rtmp" || url.scheme == "rtmps" else { return nil }

        let host = url.host ?? ""
        let port = url.port ?? 1935
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let app = pathComponents.first ?? "live"

        return RTMPURL(host: host, port: port, app: app)
    }

    private func handleConnectionState(_ newState: NWConnection.State, continuation: CheckedContinuation<Void, Error>) {
        // Only resume the continuation once
        guard !connectionContinuationResumed else {
            print("⚠️ Connection state changed to \(newState) but continuation already resumed")
            return
        }

        switch newState {
        case .ready:
            print("✅ TCP connection established")
            state = .connected
            connectionContinuationResumed = true
            continuation.resume()
        case .failed(let error):
            print("❌ Connection failed: \(error)")
            let errorMsg = error.localizedDescription
            state = .error(errorMsg)
            connectionContinuationResumed = true
            continuation.resume(throwing: RTMPError.connectionFailed(errorMsg))
        case .waiting(let error):
            print("⏳ Connection waiting: \(error)")
        case .cancelled:
            print("🚫 Connection cancelled")
            connectionContinuationResumed = true
            continuation.resume(throwing: RTMPError.connectionFailed("Cancelled"))
        default:
            break
        }
    }

    private func performHandshake() async throws {
        print("🤝 Performing RTMP handshake...")

        // C0: Version byte (0x03)
        let c0 = Data([0x03])

        // C1: 1536 bytes (timestamp + zeros + random)
        var c1 = Data(count: 1536)
        c1.replaceSubrange(0..<4, with: UInt32(0).bigEndianBytes)  // timestamp
        c1.replaceSubrange(4..<8, with: UInt32(0).bigEndianBytes)  // zero
        // Rest is random data
        for i in 8..<1536 {
            c1[i] = UInt8.random(in: 0...255)
        }

        // Send C0 + C1
        try await sendData(c0 + c1)

        // Receive S0 + S1 + S2
        let responseLength = 1 + 1536 + 1536
        guard let response = try await receiveData(length: responseLength) else {
            throw RTMPError.handshakeFailed
        }

        // Validate S0
        guard response[0] == 0x03 else {
            throw RTMPError.handshakeFailed
        }

        // Send C2 (echo of S1)
        let s1 = response.subdata(in: 1..<1537)
        try await sendData(s1)

        isHandshakeComplete = true
        print("✅ RTMP handshake complete")
    }

    private func connectToApp(_ app: String, streamKey: String) async throws {
        print("📡 Connecting to app: \(app)")

        guard let destination = destination else {
            throw RTMPError.notConnected
        }

        // Create RTMP connect command
        let tcUrl = "rtmp://\(destination.url.split(separator: "/").prefix(3).joined(separator: "/"))"
        let connectCommand = AMF0.createConnectCommand(
            app: app,
            tcUrl: tcUrl
        )

        // Send connect command (wrapped in RTMP chunk)
        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,  // AMF0 command
            messageStreamId: 0,
            payload: connectCommand
        )

        print("✅ Connect command sent")

        // TODO: Properly wait for and parse connect response
        // For now, add a small delay to let server process the commands
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Release stream
        let releaseStreamCommand = AMF0.createReleaseStreamCommand(streamName: streamKey)
        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,
            messageStreamId: 0,
            payload: releaseStreamCommand
        )

        // FCPublish
        let fcPublishCommand = AMF0.createFCPublishCommand(streamName: streamKey)
        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,
            messageStreamId: 0,
            payload: fcPublishCommand
        )

        // CreateStream
        let createStreamCommand = AMF0.createCreateStreamCommand()
        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,
            messageStreamId: 0,
            payload: createStreamCommand
        )

        print("✅ App connection complete")
    }

    private func createFLVVideoPacket(from buffer: CMSampleBuffer, timestamp: CMTime) throws -> Data {
        // Determine if this is a keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil

        return try FLVMuxer.createVideoTag(
            sampleBuffer: buffer,
            timestamp: timestamp,
            isKeyframe: isKeyframe
        )
    }

    private func createFLVAudioPacket(from buffer: CMSampleBuffer, timestamp: CMTime) throws -> Data {
        return try FLVMuxer.createAudioTag(
            sampleBuffer: buffer,
            timestamp: timestamp
        )
    }

    /// Send RTMP chunk message
    private func sendRTMPMessage(
        chunkStreamId: UInt8,
        messageTypeId: UInt8,
        messageStreamId: UInt32,
        payload: Data
    ) async throws {
        // RTMP chunk format (Type 0 - full header)
        var chunk = Data()

        // Basic header (1-3 bytes)
        // Format: 00 (Type 0) + chunk stream ID
        chunk.append(chunkStreamId & 0x3F)

        // Message header (11 bytes for Type 0)
        // Timestamp (3 bytes)
        let timestamp: UInt32 = 0
        chunk.append(UInt8((timestamp >> 16) & 0xFF))
        chunk.append(UInt8((timestamp >> 8) & 0xFF))
        chunk.append(UInt8(timestamp & 0xFF))

        // Message length (3 bytes)
        let messageLength = UInt32(payload.count)
        chunk.append(UInt8((messageLength >> 16) & 0xFF))
        chunk.append(UInt8((messageLength >> 8) & 0xFF))
        chunk.append(UInt8(messageLength & 0xFF))

        // Message type ID (1 byte)
        chunk.append(messageTypeId)

        // Message stream ID (4 bytes, little endian)
        var streamId = messageStreamId.littleEndian
        chunk.append(Data(bytes: &streamId, count: 4))

        // Payload
        chunk.append(payload)

        try await sendData(chunk)
    }

    private func sendData(_ data: Data) async throws {
        guard let connection = connection else {
            state = .error("Connection lost")
            throw RTMPError.notConnected
        }

        // Check connection state before sending
        guard connection.state == .ready else {
            state = .error("Connection not ready")
            throw RTMPError.connectionFailed("Connection state: \(connection.state)")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    Task { [weak self] in
                        await self?.handleSendError(error)
                    }
                    continuation.resume(throwing: RTMPError.connectionFailed(error.localizedDescription))
                } else {
                    Task { [weak self] in
                        await self?.updateBytesSent(UInt64(data.count))
                    }
                    continuation.resume()
                }
            })
        }
    }

    private func handleSendError(_ error: Error) {
        state = .error("Send failed: \(error.localizedDescription)")
        print("❌ RTMP send error: \(error)")
    }

    private func receiveData(length: Int) async throws -> Data? {
        guard let connection = connection else {
            throw RTMPError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: RTMPError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    private func updateBytesSent(_ bytes: UInt64) {
        bytesSent += bytes
    }

    private func calculateBitrate() -> Double {
        guard let startTime = startTime else { return 0 }
        let duration = Date().timeIntervalSince(startTime)
        guard duration > 0 else { return 0 }
        return Double(bytesSent * 8) / duration  // bits per second
    }
}
