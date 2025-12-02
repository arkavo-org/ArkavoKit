import Foundation
import Network
@preconcurrency import AVFoundation
import CoreMedia

/// RTMP subscriber for receiving live streams
///
/// Implements RTMP protocol for subscribing to live streams from RTMP servers.
/// Receives FLV container format with H.264 video and AAC audio.
public actor RTMPSubscriber {

    // MARK: - Types

    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case playing
        case error(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.connected, .connected),
                 (.playing, .playing):
                return true
            case let (.error(lhsMsg), .error(rhsMsg)):
                return lhsMsg == rhsMsg
            default:
                return false
            }
        }
    }

    public enum RTMPSubscriberError: Error, LocalizedError {
        case invalidURL
        case connectionFailed(String)
        case handshakeFailed
        case playFailed(String)
        case notConnected
        case streamNotFound
        case timeout

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid RTMP URL"
            case let .connectionFailed(reason):
                return "Connection failed: \(reason)"
            case .handshakeFailed:
                return "RTMP handshake failed"
            case let .playFailed(reason):
                return "Play failed: \(reason)"
            case .notConnected:
                return "Not connected to RTMP server"
            case .streamNotFound:
                return "Stream not found"
            case .timeout:
                return "Connection timeout"
            }
        }
    }

    /// Received media frame
    public struct MediaFrame: Sendable {
        public enum FrameType: Sendable {
            case video
            case audio
            case metadata
        }

        public let type: FrameType
        public let data: Data
        public let timestamp: UInt32  // RTMP timestamp in milliseconds
        public let isKeyframe: Bool
    }

    /// Stream metadata from onMetaData
    public struct StreamMetadata: Sendable {
        public var width: Int?
        public var height: Int?
        public var framerate: Double?
        public var videoBitrate: Double?
        public var audioBitrate: Double?
        public var videoCodec: String?
        public var audioCodec: String?
        public var ntdfHeader: String?  // Base64-encoded NanoTDF header for encrypted streams

        public init() {}
    }

    // MARK: - Properties

    private var connection: NWConnection?
    private var state: State = .disconnected
    private var isHandshakeComplete = false
    private var connectionContinuationResumed = false

    // Stream configuration
    private var streamId: UInt32 = 1
    private var transactionId: Double = 0

    // Chunk handling
    private var receiveChunkSize: Int = 128
    private var sendChunkSize: Int = 4096
    private var windowAckSize: UInt32 = 2500000
    private var serverWindowAckSize: UInt32 = 250000

    // Statistics
    private var bytesReceived: UInt64 = 0
    private var framesReceived: UInt64 = 0
    private var startTime: Date?
    private var lastAckSent: UInt64 = 0

    // Stream data
    private var metadata: StreamMetadata = StreamMetadata()
    private var videoSequenceHeader: Data?
    private var audioSequenceHeader: Data?

    // Callbacks
    private var onFrame: ((MediaFrame) async -> Void)?
    private var onMetadata: ((StreamMetadata) async -> Void)?

    // Background task for receiving frames
    private var receiveTask: Task<Void, Never>?

    // Debug
    private var verboseLogging: Bool = false

    public var currentState: State { state }
    public var currentMetadata: StreamMetadata { metadata }

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// Set callback for received frames
    public func setFrameHandler(_ handler: @escaping (MediaFrame) async -> Void) {
        onFrame = handler
    }

    /// Set callback for metadata updates
    public func setMetadataHandler(_ handler: @escaping (StreamMetadata) async -> Void) {
        onMetadata = handler
    }

    /// Enable verbose logging
    public func setVerboseLogging(_ enabled: Bool) {
        verboseLogging = enabled
    }

    /// Connect to RTMP server and start playing stream
    public func connect(url: String, streamName: String) async throws {
        guard let parsedURL = parseRTMPURL(url) else {
            throw RTMPSubscriberError.invalidURL
        }

        print("📡 Connecting to RTMP: \(parsedURL.host):\(parsedURL.port)")

        // Create TCP connection
        let host = NWEndpoint.Host(parsedURL.host)
        let port = NWEndpoint.Port(integerLiteral: UInt16(parsedURL.port))

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
        try await connectToApp(parsedURL.app)

        // Send play command
        try await sendPlayCommand(streamName: streamName)

        state = .playing
        startTime = Date()

        // Start receiving frames
        startReceiveLoop()

        print("✅ Playing stream: \(streamName)")
    }

    /// Disconnect from server
    public func disconnect() async {
        print("📡 Disconnecting from RTMP...")

        receiveTask?.cancel()
        receiveTask = nil

        connection?.cancel()
        connection = nil

        state = .disconnected
        isHandshakeComplete = false
        metadata = StreamMetadata()
        videoSequenceHeader = nil
        audioSequenceHeader = nil

        print("✅ Disconnected")
    }

    // MARK: - Connection Handling

    private func handleConnectionState(_ newState: NWConnection.State, continuation: CheckedContinuation<Void, Error>) {
        guard !connectionContinuationResumed else { return }

        switch newState {
        case .ready:
            print("✅ TCP connection established")
            state = .connected
            connectionContinuationResumed = true
            continuation.resume()
        case let .failed(error):
            print("❌ Connection failed: \(error)")
            let errorMsg = error.localizedDescription
            state = .error(errorMsg)
            connectionContinuationResumed = true
            continuation.resume(throwing: RTMPSubscriberError.connectionFailed(errorMsg))
        case let .waiting(error):
            print("⏳ Connection waiting: \(error)")
        case .cancelled:
            print("🚫 Connection cancelled")
            connectionContinuationResumed = true
            continuation.resume(throwing: RTMPSubscriberError.connectionFailed("Cancelled"))
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
        c1.replaceSubrange(0 ..< 4, with: UInt32(0).bigEndianBytes)
        c1.replaceSubrange(4 ..< 8, with: UInt32(0).bigEndianBytes)
        for i in 8 ..< 1536 {
            c1[i] = UInt8.random(in: 0 ... 255)
        }

        // Send C0 + C1
        try await sendData(c0 + c1)

        // Receive S0 + S1 + S2
        let responseLength = 1 + 1536 + 1536
        guard let response = try await receiveDataExact(length: responseLength),
              response.count == responseLength
        else {
            throw RTMPSubscriberError.handshakeFailed
        }

        print("✅ Received handshake response: \(response.count) bytes")

        // Validate S0
        guard response[0] == 0x03 else {
            throw RTMPSubscriberError.handshakeFailed
        }

        // Send C2 (echo of S1)
        let s1 = response.subdata(in: 1 ..< 1537)
        try await sendData(s1)

        isHandshakeComplete = true
        print("✅ RTMP handshake complete")
    }

    private func connectToApp(_ app: String) async throws {
        print("📡 Connecting to app: \(app)")

        // Send SetChunkSize message
        var chunkSizeData = Data()
        let newChunkSize: UInt32 = 65536
        chunkSizeData.append(contentsOf: newChunkSize.bigEndianBytes)

        try await sendRTMPMessage(
            chunkStreamId: 2,
            messageTypeId: 1,
            messageStreamId: 0,
            payload: chunkSizeData
        )
        sendChunkSize = Int(newChunkSize)

        // Send Window Acknowledgement Size
        var windowAckData = Data()
        windowAckData.append(contentsOf: windowAckSize.bigEndianBytes)

        try await sendRTMPMessage(
            chunkStreamId: 2,
            messageTypeId: 5,
            messageStreamId: 0,
            payload: windowAckData
        )

        // Reset transaction counter
        transactionId = 0

        // Create connect command
        transactionId += 1
        let connectCommand = AMF0.createConnectCommand(app: app, tcUrl: "rtmp://localhost/\(app)")

        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,
            messageStreamId: 0,
            payload: connectCommand
        )

        // Wait for connect response
        var receivedConnectResult = false
        for _ in 0 ..< 10 {
            let (messageType, messageData, messageBytes) = try await receiveRTMPMessage()
            bytesReceived += UInt64(messageBytes)

            switch messageType {
            case 1:  // Set Chunk Size
                if messageData.count >= 4 {
                    let chunkSize = UInt32(messageData[0]) << 24 | UInt32(messageData[1]) << 16 |
                        UInt32(messageData[2]) << 8 | UInt32(messageData[3])
                    receiveChunkSize = Int(chunkSize)
                    print("📥 Server Set Chunk Size: \(chunkSize)")
                }
            case 5:  // Window Acknowledgement Size
                if messageData.count >= 4 {
                    serverWindowAckSize = UInt32(messageData[0]) << 24 | UInt32(messageData[1]) << 16 |
                        UInt32(messageData[2]) << 8 | UInt32(messageData[3])
                }
            case 20:  // AMF0 Command
                receivedConnectResult = true
            default:
                break
            }

            if receivedConnectResult {
                break
            }
        }

        print("✅ Connected to app")
    }

    private func sendPlayCommand(streamName: String) async throws {
        print("📡 Sending play command for: \(streamName)")

        // CreateStream
        transactionId += 1
        let createStreamCommand = AMF0.createCreateStreamCommand(transactionId: transactionId)

        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,
            messageStreamId: 0,
            payload: createStreamCommand
        )

        // Wait for createStream response
        var receivedStreamId = false
        for _ in 0 ..< 10 {
            let (messageType, messageData, messageBytes) = try await receiveRTMPMessage()
            bytesReceived += UInt64(messageBytes)

            if messageType == 20 {  // AMF0 Command
                // Parse _result to get stream ID
                var parser = AMF0Parser(data: messageData)
                if let firstValue = try? parser.readValue(),
                   case .string = firstValue,
                   let _ = try? parser.readValue(),  // transaction ID
                   let _ = try? parser.readValue(),  // null
                   let fourthValue = try? parser.readValue(),
                   case let .number(streamIdNum) = fourthValue
                {
                    streamId = UInt32(streamIdNum)
                    receivedStreamId = true
                    print("📥 Got stream ID: \(streamId)")
                    break
                }
            }
        }

        guard receivedStreamId else {
            throw RTMPSubscriberError.playFailed("No stream ID received")
        }

        // Send play command
        transactionId += 1
        let playCommand = createPlayCommand(streamName: streamName, transactionId: transactionId)

        try await sendRTMPMessage(
            chunkStreamId: 8,
            messageTypeId: 20,
            messageStreamId: streamId,
            payload: playCommand
        )

        // Set buffer length (1000ms)
        let bufferLength = createSetBufferLengthCommand(streamId: streamId, bufferLength: 1000)
        try await sendRTMPMessage(
            chunkStreamId: 2,
            messageTypeId: 4,  // User Control
            messageStreamId: 0,
            payload: bufferLength
        )

        print("✅ Play command sent")
    }

    // MARK: - Frame Receiving

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let (messageType, messageData, timestamp, _) = try await self.receiveMediaMessage()

                    switch messageType {
                    case 8:  // Audio
                        await self.handleAudioData(messageData, timestamp: timestamp)
                    case 9:  // Video
                        await self.handleVideoData(messageData, timestamp: timestamp)
                    case 18:  // Metadata (Data AMF0)
                        await self.handleMetadata(messageData)
                    case 20:  // AMF0 Command
                        await self.handleCommand(messageData)
                    default:
                        let verbose = await self.verboseLogging
                        if verbose {
                            print("📥 Received message type \(messageType): \(messageData.count) bytes")
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        print("❌ Receive error: \(error)")
                    }
                    break
                }
            }
        }
    }

    private func handleVideoData(_ data: Data, timestamp: UInt32) async {
        guard data.count > 1 else { return }

        let frameType = (data[0] >> 4) & 0x0F
        let codecId = data[0] & 0x0F
        let isKeyframe = frameType == 1

        // Check for sequence header (AVC)
        if codecId == 7, data.count > 1, data[1] == 0 {
            videoSequenceHeader = data
            print("📥 Video sequence header: \(data.count) bytes")
            return
        }

        framesReceived += 1

        let frame = MediaFrame(
            type: .video,
            data: data,
            timestamp: timestamp,
            isKeyframe: isKeyframe
        )

        await onFrame?(frame)
    }

    private func handleAudioData(_ data: Data, timestamp: UInt32) async {
        guard data.count > 1 else { return }

        let soundFormat = (data[0] >> 4) & 0x0F

        // Check for sequence header (AAC)
        if soundFormat == 10, data.count > 1, data[1] == 0 {
            audioSequenceHeader = data
            print("📥 Audio sequence header: \(data.count) bytes")
            return
        }

        let frame = MediaFrame(
            type: .audio,
            data: data,
            timestamp: timestamp,
            isKeyframe: false
        )

        await onFrame?(frame)
    }

    private func handleMetadata(_ data: Data) async {
        print("📥 Metadata: \(data.count) bytes")

        // Parse AMF0 metadata
        var parser = AMF0Parser(data: data)

        // Read all values
        while parser.bytesRemaining > 0 {
            guard let value = try? parser.readValue() else { break }

            // Look for object/array with metadata fields
            if case let .object(dict) = value {
                parseMetadataDict(dict)
            } else if case let .array(arr) = value {
                for item in arr {
                    if case let .object(dict) = item {
                        parseMetadataDict(dict)
                    }
                }
            }
        }

        await onMetadata?(metadata)
    }

    private func parseMetadataDict(_ dict: [String: AMF0Parser.Value]) {
        if case let .number(width) = dict["width"] {
            metadata.width = Int(width)
        }
        if case let .number(height) = dict["height"] {
            metadata.height = Int(height)
        }
        if case let .number(framerate) = dict["framerate"] {
            metadata.framerate = framerate
        }
        if case let .number(videoBitrate) = dict["videodatarate"] {
            metadata.videoBitrate = videoBitrate * 1000
        }
        if case let .number(audioBitrate) = dict["audiodatarate"] {
            metadata.audioBitrate = audioBitrate * 1000
        }
        if case let .string(videoCodec) = dict["videocodecid"] {
            metadata.videoCodec = videoCodec
        }
        if case let .string(audioCodec) = dict["audiocodecid"] {
            metadata.audioCodec = audioCodec
        }
        // NTDF-RTMP: Extract encrypted stream header
        if case let .string(ntdfHeader) = dict["ntdf_header"] {
            metadata.ntdfHeader = ntdfHeader
            print("🔐 Received ntdf_header: \(ntdfHeader.prefix(50))...")
        }
    }

    private func handleCommand(_ data: Data) async {
        var parser = AMF0Parser(data: data)
        guard let firstValue = try? parser.readValue(),
              case let .string(commandName) = firstValue
        else { return }

        print("📥 Command: \(commandName)")

        switch commandName {
        case "onStatus":
            // Handle stream status - skip transaction ID and null
            _ = try? parser.readValue()  // transaction ID
            _ = try? parser.readValue()  // null

            // Read info object
            if let infoValue = try? parser.readValue(),
               case let .object(info) = infoValue,
               case let .string(code) = info["code"]
            {
                print("📥 Stream status: \(code)")

                if code == "NetStream.Play.StreamNotFound" {
                    state = .error("Stream not found")
                }
            }
        default:
            break
        }
    }

    // MARK: - RTMP Protocol

    private func receiveMediaMessage() async throws -> (messageType: UInt8, data: Data, timestamp: UInt32, bytes: Int) {
        let (messageType, data, bytes) = try await receiveRTMPMessage()
        // TODO: Extract timestamp from chunk header properly
        return (messageType, data, 0, bytes)
    }

    private func receiveRTMPMessage() async throws -> (messageType: UInt8, data: Data, bytes: Int) {
        // Read chunk basic header
        guard let basicHeader = try await receiveDataExact(length: 1) else {
            throw RTMPSubscriberError.connectionFailed("Failed to read chunk header")
        }

        var totalBytes = 1
        let format = (basicHeader[0] >> 6) & 0x03
        var chunkStreamId = UInt32(basicHeader[0] & 0x3F)

        // Extended chunk stream ID
        if chunkStreamId == 0 {
            guard let extByte = try await receiveDataExact(length: 1) else {
                throw RTMPSubscriberError.connectionFailed("Failed to read extended csid")
            }
            chunkStreamId = UInt32(extByte[0]) + 64
            totalBytes += 1
        } else if chunkStreamId == 1 {
            guard let extBytes = try await receiveDataExact(length: 2) else {
                throw RTMPSubscriberError.connectionFailed("Failed to read extended csid")
            }
            chunkStreamId = UInt32(extBytes[1]) * 256 + UInt32(extBytes[0]) + 64
            totalBytes += 2
        }

        // Read message header based on format
        var messageLength: UInt32 = 0
        var messageTypeId: UInt8 = 0
        var timestamp: UInt32 = 0

        switch format {
        case 0:  // Full header (11 bytes)
            guard let header = try await receiveDataExact(length: 11) else {
                throw RTMPSubscriberError.connectionFailed("Failed to read type 0 header")
            }
            totalBytes += 11
            timestamp = UInt32(header[0]) << 16 | UInt32(header[1]) << 8 | UInt32(header[2])
            messageLength = UInt32(header[3]) << 16 | UInt32(header[4]) << 8 | UInt32(header[5])
            messageTypeId = header[6]

        case 1:  // 7 bytes (no stream id)
            guard let header = try await receiveDataExact(length: 7) else {
                throw RTMPSubscriberError.connectionFailed("Failed to read type 1 header")
            }
            totalBytes += 7
            timestamp = UInt32(header[0]) << 16 | UInt32(header[1]) << 8 | UInt32(header[2])
            messageLength = UInt32(header[3]) << 16 | UInt32(header[4]) << 8 | UInt32(header[5])
            messageTypeId = header[6]

        case 2:  // 3 bytes (timestamp delta only)
            guard let header = try await receiveDataExact(length: 3) else {
                throw RTMPSubscriberError.connectionFailed("Failed to read type 2 header")
            }
            totalBytes += 3
            timestamp = UInt32(header[0]) << 16 | UInt32(header[1]) << 8 | UInt32(header[2])
            // Use previous message length and type

        case 3:  // 0 bytes (continuation)
            // Use previous everything
            break

        default:
            break
        }

        // Extended timestamp
        if timestamp == 0xFF_FFFF {
            guard let extTs = try await receiveDataExact(length: 4) else {
                throw RTMPSubscriberError.connectionFailed("Failed to read extended timestamp")
            }
            totalBytes += 4
            timestamp = UInt32(extTs[0]) << 24 | UInt32(extTs[1]) << 16 |
                UInt32(extTs[2]) << 8 | UInt32(extTs[3])
        }

        // Read payload in chunks
        var payload = Data()
        var remaining = Int(messageLength)

        while remaining > 0 {
            let chunkSize = min(remaining, receiveChunkSize)
            guard let chunk = try await receiveDataExact(length: chunkSize) else {
                throw RTMPSubscriberError.connectionFailed("Failed to read chunk payload")
            }
            payload.append(chunk)
            totalBytes += chunkSize
            remaining -= chunkSize

            // Read continuation header if more chunks
            if remaining > 0 {
                guard let contHeader = try await receiveDataExact(length: 1) else {
                    throw RTMPSubscriberError.connectionFailed("Failed to read continuation header")
                }
                totalBytes += 1
                // Verify it's a type 3 continuation
                let contFormat = (contHeader[0] >> 6) & 0x03
                if contFormat != 3 {
                    print("⚠️ Expected type 3 continuation, got type \(contFormat)")
                }
            }
        }

        // Send acknowledgement if needed
        bytesReceived += UInt64(totalBytes)
        if bytesReceived - lastAckSent >= UInt64(serverWindowAckSize) {
            try await sendAcknowledgement()
            lastAckSent = bytesReceived
        }

        return (messageTypeId, payload, totalBytes)
    }

    private func sendRTMPMessage(chunkStreamId: UInt8, messageTypeId: UInt8, messageStreamId: UInt32, payload: Data) async throws {
        var data = Data()

        // Basic header (format 0, full header)
        data.append((0 << 6) | chunkStreamId)

        // Message header (11 bytes for format 0)
        data.append(contentsOf: [0, 0, 0])  // Timestamp
        let length = UInt32(payload.count)
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(messageTypeId)
        data.append(contentsOf: messageStreamId.littleEndianBytes)

        // Payload (chunked if necessary)
        var offset = 0
        while offset < payload.count {
            if offset > 0 {
                // Type 3 continuation header
                data.append((3 << 6) | chunkStreamId)
            }

            let chunkSize = min(sendChunkSize, payload.count - offset)
            data.append(payload.subdata(in: offset ..< offset + chunkSize))
            offset += chunkSize
        }

        try await sendData(data)
    }

    private func sendAcknowledgement() async throws {
        var data = Data()
        let sequenceNumber = UInt32(bytesReceived)
        data.append(contentsOf: sequenceNumber.bigEndianBytes)

        try await sendRTMPMessage(
            chunkStreamId: 2,
            messageTypeId: 3,  // Acknowledgement
            messageStreamId: 0,
            payload: data
        )
    }

    // MARK: - Command Creation

    private func createPlayCommand(streamName: String, transactionId: Double) -> Data {
        var data = Data()

        // Command name: "play"
        data.append(0x02)  // String marker
        let name = "play"
        data.append(contentsOf: UInt16(name.count).bigEndianBytes)
        data.append(name.data(using: .utf8)!)

        // Transaction ID
        data.append(0x00)  // Number marker
        var txnId = transactionId
        withUnsafeBytes(of: &txnId) { data.append(contentsOf: $0.reversed()) }

        // Null (command object)
        data.append(0x05)

        // Stream name
        data.append(0x02)
        data.append(contentsOf: UInt16(streamName.count).bigEndianBytes)
        data.append(streamName.data(using: .utf8)!)

        // Start: -2 (play live)
        data.append(0x00)
        var start: Double = -2
        withUnsafeBytes(of: &start) { data.append(contentsOf: $0.reversed()) }

        return data
    }

    private func createSetBufferLengthCommand(streamId: UInt32, bufferLength: UInt32) -> Data {
        var data = Data()

        // Event type: SetBufferLength (3)
        data.append(contentsOf: UInt16(3).bigEndianBytes)

        // Stream ID
        data.append(contentsOf: streamId.bigEndianBytes)

        // Buffer length in ms
        data.append(contentsOf: bufferLength.bigEndianBytes)

        return data
    }

    // MARK: - Network I/O

    private func sendData(_ data: Data) async throws {
        guard let connection else {
            throw RTMPSubscriberError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RTMPSubscriberError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveDataExact(length: Int) async throws -> Data? {
        guard let connection else {
            throw RTMPSubscriberError.notConnected
        }

        var receivedData = Data()

        while receivedData.count < length {
            let remaining = length - receivedData.count

            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: RTMPSubscriberError.connectionFailed(error.localizedDescription))
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }

            guard let data else {
                return nil
            }
            receivedData.append(data)
        }

        return receivedData
    }

    // MARK: - URL Parsing

    private struct ParsedURL {
        let host: String
        let port: Int
        let app: String
    }

    private func parseRTMPURL(_ urlString: String) -> ParsedURL? {
        // Format: rtmp://host:port/app or rtmp://host/app
        var url = urlString

        // Remove rtmp:// prefix
        if url.hasPrefix("rtmp://") {
            url = String(url.dropFirst(7))
        } else if url.hasPrefix("rtmps://") {
            url = String(url.dropFirst(8))
        } else {
            return nil
        }

        // Split host:port/app
        let parts = url.split(separator: "/", maxSplits: 1)
        guard parts.count >= 1 else { return nil }

        let hostPort = String(parts[0])
        let app = parts.count > 1 ? String(parts[1]) : "live"

        // Parse host and port
        let hostParts = hostPort.split(separator: ":")
        let host = String(hostParts[0])
        let port = hostParts.count > 1 ? Int(hostParts[1]) ?? 1935 : 1935

        return ParsedURL(host: host, port: port, app: app)
    }
}

// MARK: - Extensions

extension UInt32 {
    var littleEndianBytes: [UInt8] {
        [
            UInt8(self & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 24) & 0xFF),
        ]
    }
}
