import Foundation
import Network
import os
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

        public init() { /* Uses default property values */ }
    }

    struct ParsedURL: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: UInt16
        let app: String

        var useTLS: Bool { scheme == "rtmps" }

        var tcUrl: String {
            let defaultPort: UInt16 = useTLS ? 443 : 1935
            if port == defaultPort {
                return "\(scheme)://\(host)/\(app)"
            }
            return "\(scheme)://\(host):\(port)/\(app)"
        }
    }

    // MARK: - Properties

    private var connection: NWConnection?
    private var state: State = .disconnected
    private var isHandshakeComplete = false

    public let connectTimeout: TimeInterval

    // Pending `connect` continuation settled at most once via `finishConnect`.
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectTimeoutTask: Task<Void, Never>?

    // Stream configuration
    private var streamId: UInt32 = 1
    private var transactionId: Double = 0

    // Chunk handling
    private var receiveChunkSize: Int = 128
    private var sendChunkSize: Int = 4096
    private var windowAckSize: UInt32 = 2500000
    private var serverWindowAckSize: UInt32 = 250000

    // Per-chunk-stream state for full interleaved RTMP chunk reassembly
    private struct ChunkStreamState {
        var messageLength: UInt32 = 0
        var messageTypeId: UInt8 = 0
        var timestamp: UInt32 = 0
        var timestampDelta: UInt32 = 0
        var remainingBytes: UInt32 = 0
        var hasExtendedTimestamp: Bool = false
        var payloadBuffer: Data = Data()
    }
    private var chunkStreamStates: [UInt32: ChunkStreamState] = [:]

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

    public init(connectTimeout: TimeInterval = 10) {
        self.connectTimeout = connectTimeout
    }

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
        guard let parsedURL = Self.parseRTMPURL(url),
              let nwPort = NWEndpoint.Port(rawValue: parsedURL.port) else {
            throw RTMPSubscriberError.invalidURL
        }

        // Clean up any prior session and reset all protocol state
        resetConnectionState(cancelReason: "Superseded by new connect")

        print("📡 Connecting to \(parsedURL.scheme.uppercased()): \(parsedURL.host):\(parsedURL.port)")

        // Create TCP or TLS connection depending on scheme (rtmp:// vs rtmps://)
        let host = NWEndpoint.Host(parsedURL.host)
        let parameters: NWParameters = parsedURL.useTLS ? .tls : .tcp

        let newConnection = NWConnection(host: host, port: nwPort, using: parameters)
        connection = newConnection

        state = .connecting

        // Start connection with timeout and once-settled continuation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation

            newConnection.stateUpdateHandler = { [weak self, weak newConnection] newState in
                Task { [weak self] in
                    await self?.handleConnectionState(newState, from: newConnection)
                }
            }

            let timeout = connectTimeout
            connectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                await self?.connectTimedOut(host: parsedURL.host, port: Int(parsedURL.port))
            }

            newConnection.start(queue: .global(qos: .userInitiated))
        }

        do {
            // Perform RTMP handshake
            try await performHandshake()

            // Connect to application
            try await connectToApp(parsedURL)

            // Send play command
            try await sendPlayCommand(streamName: streamName)
        } catch {
            newConnection.cancel()
            if connection === newConnection {
                connection = nil
            }
            state = .error(error.localizedDescription)
            throw error
        }

        state = .playing
        startTime = Date()

        // Start receiving frames
        startReceiveLoop()

        print("✅ Playing stream: \(streamName)")
    }

    /// Disconnect from server
    public func disconnect() async {
        print("📡 Disconnecting from RTMP...")
        resetConnectionState(cancelReason: "Cancelled")
        print("✅ Disconnected")
    }

    private func resetConnectionState(cancelReason: String) {
        receiveTask?.cancel()
        receiveTask = nil

        finishConnect(.failure(RTMPSubscriberError.connectionFailed(cancelReason)))

        connection?.cancel()
        connection = nil

        state = .disconnected
        isHandshakeComplete = false
        receiveChunkSize = 128
        sendChunkSize = 4096
        serverWindowAckSize = 250000
        bytesReceived = 0
        framesReceived = 0
        lastAckSent = 0
        startTime = nil
        streamId = 1
        transactionId = 0
        chunkStreamStates.removeAll()
        metadata = StreamMetadata()
        videoSequenceHeader = nil
        audioSequenceHeader = nil
    }

    // MARK: - Connection Handling

    private func finishConnect(_ result: Result<Void, Error>) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil

        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume(with: result)
    }

    private func connectTimedOut(host: String, port: Int) {
        guard connectContinuation != nil else { return }
        print("❌ Connection to \(host):\(port) timed out after \(Int(connectTimeout))s")
        state = .error(RTMPSubscriberError.timeout.localizedDescription)
        connection?.cancel()
        connection = nil
        finishConnect(.failure(RTMPSubscriberError.timeout))
    }

    private func handleConnectionState(_ newState: NWConnection.State, from source: NWConnection?) {
        guard let source, source === connection else { return }

        switch newState {
        case .ready:
            print("✅ TCP connection established")
            state = .connected
            finishConnect(.success(()))
        case let .failed(error):
            let errorMsg = "\(error)"
            print("❌ Connection failed: \(errorMsg)")
            guard connectContinuation != nil else { return }
            state = .error(errorMsg)
            finishConnect(.failure(RTMPSubscriberError.connectionFailed(errorMsg)))
        case let .waiting(error):
            print("⏳ Connection waiting: \(error)")
        case .cancelled:
            print("🚫 Connection cancelled")
            guard connectContinuation != nil else { return }
            finishConnect(.failure(RTMPSubscriberError.connectionFailed("Cancelled")))
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
        let handshakeTimeout = Duration.seconds(max(10, connectTimeout))
        let responseLength = 1 + 1536 + 1536
        guard let response = try await receiveDataExact(length: responseLength, timeout: handshakeTimeout),
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

    /// Process RTMP protocol control messages (types 1, 3, 4, 5, 6).
    /// Returns `true` if the message was a control message and handled here.
    private func handleControlMessage(type: UInt8, data: Data) async throws -> Bool {
        switch type {
        case 1:  // Set Chunk Size
            guard data.count >= 4 else { return true }
            let rawSize = (UInt32(data[0]) << 24 | UInt32(data[1]) << 16 |
                           UInt32(data[2]) << 8 | UInt32(data[3])) & 0x7FFF_FFFF
            guard rawSize > 0 else {
                throw RTMPSubscriberError.connectionFailed("Invalid server SetChunkSize: 0")
            }
            receiveChunkSize = Int(rawSize)
            print("📥 Server Set Chunk Size: \(rawSize)")
            return true

        case 3:  // Acknowledgement
            return true

        case 4:  // User Control Message
            if data.count >= 6 {
                let eventType = UInt16(data[0]) << 8 | UInt16(data[1])
                if eventType == 6 {  // Ping Request -> send Ping Response (Pong)
                    let pingTimestamp = UInt32(data[2]) << 24 | UInt32(data[3]) << 16 |
                                        UInt32(data[4]) << 8 | UInt32(data[5])
                    var pongPayload = Data([0x00, 0x07])
                    pongPayload.append(contentsOf: pingTimestamp.bigEndianBytes)
                    try await sendRTMPMessage(
                        chunkStreamId: 2,
                        messageTypeId: 4,
                        messageStreamId: 0,
                        payload: pongPayload
                    )
                }
            }
            return true

        case 5:  // Window Acknowledgement Size
            if data.count >= 4 {
                let size = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 |
                           UInt32(data[2]) << 8 | UInt32(data[3])
                if size > 0 {
                    serverWindowAckSize = size
                    print("📥 Server Window Ack Size: \(serverWindowAckSize)")
                }
            }
            return true

        case 6:  // Set Peer Bandwidth
            return true

        default:
            return false
        }
    }

    private func extractAMFErrorReason(from values: [AMF0Parser.Value]) -> String {
        for value in values.dropFirst() {
            if case let .object(dict) = value {
                if let code = dict["code"]?.stringValue, !code.isEmpty {
                    if let desc = dict["description"]?.stringValue, !desc.isEmpty {
                        return "\(code): \(desc)"
                    }
                    return code
                }
                if let desc = dict["description"]?.stringValue, !desc.isEmpty {
                    return desc
                }
            }
        }
        return "Server returned _error"
    }

    private func connectToApp(_ parsedURL: ParsedURL) async throws {
        print("📡 Connecting to app: \(parsedURL.app)")

        let controlTimeout = Duration.seconds(max(10, connectTimeout))

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

        // Create connect command with actual parsed tcUrl
        transactionId += 1
        let connectCommand = AMF0.createConnectCommand(app: parsedURL.app, tcUrl: parsedURL.tcUrl)

        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,
            messageStreamId: 0,
            payload: connectCommand
        )

        // Wait for connect _result (rejecting _error)
        var receivedConnectResult = false
        for _ in 0 ..< 25 {
            let (messageType, messageData, _, _) = try await receiveRTMPMessage(firstByteTimeout: controlTimeout)

            if try await handleControlMessage(type: messageType, data: messageData) {
                continue
            }

            if messageType == 20 {  // AMF0 Command
                var parser = AMF0Parser(data: messageData)
                let values = (try? parser.readAllValues()) ?? []
                let cmdName = values.first?.stringValue
                let txnId = values.count > 1 ? values[1].numberValue : nil

                if cmdName == "_error" {
                    throw RTMPSubscriberError.connectionFailed(extractAMFErrorReason(from: values))
                }
                if cmdName == "_result", txnId == 1.0 {
                    receivedConnectResult = true
                    break
                }
            }
        }

        guard receivedConnectResult else {
            throw RTMPSubscriberError.connectionFailed("Did not receive connect _result from server")
        }

        print("✅ Connected to app")
    }

    private func sendPlayCommand(streamName: String) async throws {
        print("📡 Sending play command for: \(streamName)")

        let controlTimeout = Duration.seconds(max(10, connectTimeout))

        // CreateStream
        transactionId += 1
        let createStreamTxnId = transactionId
        let createStreamCommand = AMF0.createCreateStreamCommand(transactionId: createStreamTxnId)

        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,
            messageStreamId: 0,
            payload: createStreamCommand
        )

        // Wait for createStream _result response while handling control messages
        var receivedStreamId = false
        for _ in 0 ..< 25 {
            let (messageType, messageData, _, _) = try await receiveRTMPMessage(firstByteTimeout: controlTimeout)

            if try await handleControlMessage(type: messageType, data: messageData) {
                continue
            }

            if messageType == 20 {  // AMF0 Command
                var parser = AMF0Parser(data: messageData)
                let values = (try? parser.readAllValues()) ?? []
                guard let cmdName = values.first?.stringValue else { continue }

                if cmdName == "_error" {
                    throw RTMPSubscriberError.playFailed(extractAMFErrorReason(from: values))
                }

                if cmdName == "_result",
                   values.count >= 4,
                   values[1].numberValue == createStreamTxnId,
                   case let .number(streamIdNum) = values[3],
                   streamIdNum.isFinite,
                   streamIdNum >= 0,
                   streamIdNum <= Double(UInt32.max)
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

            print("🔄 Starting receive loop...")
            while !Task.isCancelled {
                do {
                    let (messageType, messageData, timestamp, _) = try await self.receiveMediaMessage()

                    // Handle RTMP control messages (SetChunkSize, PingRequest -> Pong, WindowAckSize)
                    if try await self.handleControlMessage(type: messageType, data: messageData) {
                        continue
                    }

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
                        break
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if !Task.isCancelled {
                        print("❌ Receive error: \(error)")
                        await self.handleReceiveLoopFailure(error)
                    }
                    break
                }
            }
        }
    }

    private func handleReceiveLoopFailure(_ error: Error) {
        if state != .disconnected {
            state = .error(error.localizedDescription)
        }
        connection?.cancel()
        connection = nil
        receiveTask = nil
    }

    private func handleVideoData(_ data: Data, timestamp: UInt32) async {
        guard data.count > 1 else { return }

        let frameType = (data[0] >> 4) & 0x0F
        let codecId = data[0] & 0x0F
        let isKeyframe = frameType == 1

        // Check for sequence header (AVC)
        let isSequenceHeader = codecId == 7 && data[1] == 0
        if isSequenceHeader {
            videoSequenceHeader = data
            print("📥 Video sequence header: \(data.count) bytes")
        }

        framesReceived += 1

        let frame = MediaFrame(
            type: .video,
            data: data,
            timestamp: timestamp,
            isKeyframe: isKeyframe || isSequenceHeader
        )

        await onFrame?(frame)
    }

    private func handleAudioData(_ data: Data, timestamp: UInt32) async {
        guard data.count > 1 else { return }

        let soundFormat = (data[0] >> 4) & 0x0F

        // Check for sequence header (AAC)
        let isSequenceHeader = soundFormat == 10 && data[1] == 0
        if isSequenceHeader {
            audioSequenceHeader = data
            print("📥 Audio sequence header: \(data.count) bytes")
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
        var parser = AMF0Parser(data: data)

        while parser.bytesRemaining > 0 {
            do {
                let value = try parser.readValue()

                if case let .object(dict) = value {
                    parseMetadataDict(dict)
                } else if case let .array(arr) = value {
                    for item in arr {
                        if case let .object(dict) = item {
                            parseMetadataDict(dict)
                        }
                    }
                }
            } catch {
                break
            }
        }

        if metadata.ntdfHeader != nil {
            print("📥 [RTMPSub] Metadata received with NTDF header")
        }
        await onMetadata?(metadata)
    }

    private func parseMetadataDict(_ dict: [String: AMF0Parser.Value]) {
        if case let .number(width) = dict["width"],
           width.isFinite, width >= 0, width <= Double(Int.max) {
            metadata.width = Int(width)
        }
        if case let .number(height) = dict["height"],
           height.isFinite, height >= 0, height <= Double(Int.max) {
            metadata.height = Int(height)
        }
        if case let .number(framerate) = dict["framerate"], framerate.isFinite {
            metadata.framerate = framerate
        }
        if case let .number(videoBitrate) = dict["videodatarate"], videoBitrate.isFinite {
            metadata.videoBitrate = videoBitrate * 1000
        }
        if case let .number(audioBitrate) = dict["audiodatarate"], audioBitrate.isFinite {
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
            _ = try? parser.readValue()  // transaction ID
            _ = try? parser.readValue()  // null

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
        try await receiveRTMPMessage(firstByteTimeout: .seconds(10))
    }

    /// Receive and reassemble the next complete RTMP message across any number of
    /// interleaved chunk streams. Every chunk stream keeps its own `payloadBuffer`
    /// and `remainingBytes`, so interleaved messages are never dropped or desynced.
    private func receiveRTMPMessage(
        firstByteTimeout: Duration? = .seconds(10)
    ) async throws -> (messageType: UInt8, data: Data, timestamp: UInt32, bytes: Int) {
        var totalBytes = 0
        let inMessageTimeout: Duration = firstByteTimeout ?? .seconds(10)
        var isFirstChunk = true

        while true {
            let basicTimeout = isFirstChunk ? firstByteTimeout : inMessageTimeout
            isFirstChunk = false

            // Read chunk basic header
            guard let basicHeader = try await receiveDataExact(length: 1, timeout: basicTimeout) else {
                throw RTMPSubscriberError.connectionFailed("Failed to read chunk header")
            }

            var chunkWireBytes = 1
            let format = (basicHeader[0] >> 6) & 0x03
            var chunkStreamId = UInt32(basicHeader[0] & 0x3F)

            // Extended chunk stream ID (RTMP spec section 5.3.1.1)
            if chunkStreamId == 0 {
                guard let extByte = try await receiveDataExact(length: 1, timeout: inMessageTimeout) else {
                    throw RTMPSubscriberError.connectionFailed("Failed to read extended csid")
                }
                chunkStreamId = UInt32(extByte[0]) + 64
                chunkWireBytes += 1
            } else if chunkStreamId == 1 {
                guard let extBytes = try await receiveDataExact(length: 2, timeout: inMessageTimeout) else {
                    throw RTMPSubscriberError.connectionFailed("Failed to read extended csid")
                }
                chunkStreamId = UInt32(extBytes[1]) * 256 + UInt32(extBytes[0]) + 64
                chunkWireBytes += 2
            }

            var csState = chunkStreamStates[chunkStreamId] ?? ChunkStreamState()
            var rawTimestampField: UInt32 = 0

            switch format {
            case 0:  // Full header (11 bytes)
                guard let header = try await receiveDataExact(length: 11, timeout: inMessageTimeout) else {
                    throw RTMPSubscriberError.connectionFailed("Failed to read type 0 header")
                }
                chunkWireBytes += 11
                rawTimestampField = UInt32(header[0]) << 16 | UInt32(header[1]) << 8 | UInt32(header[2])
                csState.messageLength = UInt32(header[3]) << 16 | UInt32(header[4]) << 8 | UInt32(header[5])
                csState.messageTypeId = header[6]
                csState.timestampDelta = 0
                if rawTimestampField != 0xFF_FFFF {
                    csState.timestamp = rawTimestampField
                    csState.hasExtendedTimestamp = false
                } else {
                    csState.hasExtendedTimestamp = true
                }
                csState.payloadBuffer = Data()
                csState.remainingBytes = csState.messageLength

            case 1:  // 7 bytes (no stream id) - timestamp is DELTA
                guard let header = try await receiveDataExact(length: 7, timeout: inMessageTimeout) else {
                    throw RTMPSubscriberError.connectionFailed("Failed to read type 1 header")
                }
                chunkWireBytes += 7
                rawTimestampField = UInt32(header[0]) << 16 | UInt32(header[1]) << 8 | UInt32(header[2])
                csState.messageLength = UInt32(header[3]) << 16 | UInt32(header[4]) << 8 | UInt32(header[5])
                csState.messageTypeId = header[6]
                if rawTimestampField != 0xFF_FFFF {
                    csState.timestampDelta = rawTimestampField
                    csState.timestamp &+= rawTimestampField
                    csState.hasExtendedTimestamp = false
                } else {
                    csState.hasExtendedTimestamp = true
                }
                csState.payloadBuffer = Data()
                csState.remainingBytes = csState.messageLength

            case 2:  // 3 bytes (timestamp delta only)
                guard let header = try await receiveDataExact(length: 3, timeout: inMessageTimeout) else {
                    throw RTMPSubscriberError.connectionFailed("Failed to read type 2 header")
                }
                chunkWireBytes += 3
                rawTimestampField = UInt32(header[0]) << 16 | UInt32(header[1]) << 8 | UInt32(header[2])
                if rawTimestampField != 0xFF_FFFF {
                    csState.timestampDelta = rawTimestampField
                    csState.timestamp &+= rawTimestampField
                    csState.hasExtendedTimestamp = false
                } else {
                    csState.hasExtendedTimestamp = true
                }
                csState.payloadBuffer = Data()
                csState.remainingBytes = csState.messageLength

            default:  // Type 3 (0-byte message header)
                if csState.remainingBytes == 0 {
                    // Starting a new message with same length/type and prior timestamp delta
                    if !csState.hasExtendedTimestamp {
                        csState.timestamp &+= csState.timestampDelta
                    }
                    csState.payloadBuffer = Data()
                    csState.remainingBytes = csState.messageLength
                }
            }

            // Extended timestamp handling
            let needsExtendedTimestamp = (format != 3 && rawTimestampField == 0xFF_FFFF) ||
                                         (format == 3 && csState.hasExtendedTimestamp)
            if needsExtendedTimestamp {
                guard let extTs = try await receiveDataExact(length: 4, timeout: inMessageTimeout) else {
                    throw RTMPSubscriberError.connectionFailed("Failed to read extended timestamp")
                }
                chunkWireBytes += 4
                let extendedTimestamp = UInt32(extTs[0]) << 24 | UInt32(extTs[1]) << 16 |
                                        UInt32(extTs[2]) << 8 | UInt32(extTs[3])
                if format == 0 {
                    csState.timestamp = extendedTimestamp
                } else if format == 1 || format == 2 {
                    csState.timestampDelta = extendedTimestamp
                    csState.timestamp &+= extendedTimestamp
                } else if csState.payloadBuffer.isEmpty {
                    // Type 3 starting a new message carrying an extended timestamp delta
                    csState.timestampDelta = extendedTimestamp
                    csState.timestamp &+= extendedTimestamp
                }
            }

            // Read one chunk's worth of payload using remainingBytes (never full messageLength)
            guard receiveChunkSize > 0 else {
                throw RTMPSubscriberError.connectionFailed("Invalid receiveChunkSize: \(receiveChunkSize)")
            }

            let chunkSize = min(Int(csState.remainingBytes), receiveChunkSize)
            if chunkSize > 0 {
                guard let chunk = try await receiveDataExact(length: chunkSize, timeout: inMessageTimeout) else {
                    throw RTMPSubscriberError.connectionFailed("Failed to read chunk payload")
                }
                csState.payloadBuffer.append(chunk)
                csState.remainingBytes -= UInt32(chunkSize)
                chunkWireBytes += chunkSize
            }

            totalBytes += chunkWireBytes
            bytesReceived += UInt64(chunkWireBytes)

            if serverWindowAckSize > 0 && bytesReceived - lastAckSent >= UInt64(serverWindowAckSize) {
                print("📤 [RTMPSub] Sending acknowledgement: bytesReceived=\(bytesReceived)")
                try await sendAcknowledgement()
                lastAckSent = bytesReceived
            }

            if csState.remainingBytes == 0 {
                let completedPayload = csState.payloadBuffer
                let completedType = csState.messageTypeId
                let completedTimestamp = csState.timestamp
                csState.payloadBuffer = Data()
                chunkStreamStates[chunkStreamId] = csState
                return (completedType, completedPayload, completedTimestamp, totalBytes)
            } else {
                chunkStreamStates[chunkStreamId] = csState
            }
        }
    }

    private func sendRTMPMessage(chunkStreamId: UInt8, messageTypeId: UInt8, messageStreamId: UInt32, payload: Data) async throws {
        var data = Data()
        let normalizedPayload = payload.startIndex == 0 ? payload : Data(payload)

        // Basic header (format 0, full header)
        data.append(chunkStreamId & 0x3F)

        // Message header (11 bytes for format 0)
        data.append(contentsOf: [0, 0, 0])  // Timestamp
        let length = UInt32(normalizedPayload.count)
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(messageTypeId)
        data.append(contentsOf: messageStreamId.littleEndianBytes)

        // Payload (chunked if necessary)
        var offset = 0
        while offset < normalizedPayload.count {
            if offset > 0 {
                // Type 3 continuation header
                data.append(0xC0 | (chunkStreamId & 0x3F))
            }

            let chunkSize = min(sendChunkSize, normalizedPayload.count - offset)
            data.append(normalizedPayload.subdata(in: offset ..< (offset + chunkSize)))
            offset += chunkSize
        }

        try await sendData(data)
    }

    private func sendAcknowledgement() async throws {
        var data = Data()
        // Wrap cleanly modulo 2^32 after 4 GiB received per RTMP spec
        let sequenceNumber = UInt32(truncatingIfNeeded: bytesReceived)
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
        data.append(AMF0.encodeString("play"))
        data.append(AMF0.encodeNumber(transactionId))
        data.append(AMF0.encodeNull())
        data.append(AMF0.encodeString(streamName))
        data.append(AMF0.encodeNumber(-2.0))  // Start: -2 (play live)
        return data
    }

    private func createSetBufferLengthCommand(streamId: UInt32, bufferLength: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: UInt16(3).bigEndianBytes)  // Event type: SetBufferLength (3)
        data.append(contentsOf: streamId.bigEndianBytes)
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

    /// Receive exact amount of data, enforcing an actual deadline even when the peer sends 0 bytes,
    /// and delivering non-empty final TCP data before observing `isComplete`.
    private func receiveDataExact(length: Int, timeout: Duration? = .seconds(10)) async throws -> Data? {
        guard let connection else {
            throw RTMPSubscriberError.notConnected
        }
        guard length > 0 else { return Data() }

        var receivedData = Data()
        receivedData.reserveCapacity(length)
        let deadline = timeout.map { ContinuousClock.now.advanced(by: $0) }

        while receivedData.count < length {
            let remaining = length - receivedData.count

            let stepTimeout: Duration?
            if let deadline {
                let remainingTime = ContinuousClock.now.duration(to: deadline)
                if remainingTime <= .zero {
                    print("⏰ [RTMPSub] Receive timeout waiting for \(length) bytes (got \(receivedData.count))")
                    connection.cancel()
                    throw RTMPSubscriberError.connectionFailed("Receive timeout")
                }
                stepTimeout = remainingTime
            } else {
                stepTimeout = nil
            }

            let chunk = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                    let settled = OSAllocatedUnfairLock(initialState: false)
                    let timeoutTask: Task<Void, Never>?

                    if let stepTimeout {
                        timeoutTask = Task {
                            try? await Task.sleep(for: stepTimeout)
                            let shouldFail = settled.withLock { already -> Bool in
                                if already { return false }
                                already = true
                                return true
                            }
                            if shouldFail {
                                connection.cancel()
                                continuation.resume(throwing: RTMPSubscriberError.connectionFailed("Receive timeout"))
                            }
                        }
                    } else {
                        timeoutTask = nil
                    }

                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                        timeoutTask?.cancel()
                        let shouldResume = settled.withLock { already -> Bool in
                            if already { return false }
                            already = true
                            return true
                        }
                        guard shouldResume else { return }

                        // Process non-empty data BEFORE checking isComplete so final TCP bytes are never dropped
                        if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                            return
                        }

                        if let error {
                            print("❌ [RTMPSub] Connection receive error: \(error.localizedDescription)")
                            continuation.resume(throwing: RTMPSubscriberError.connectionFailed(error.localizedDescription))
                            return
                        }

                        if isComplete {
                            print("⚠️ [RTMPSub] Connection closed by server (isComplete=true)")
                            continuation.resume(returning: nil)
                            return
                        }

                        continuation.resume(returning: nil)
                    }
                }
            } onCancel: {
                connection.cancel()
            }

            guard let chunk else {
                return nil
            }
            receivedData.append(chunk)
        }

        return receivedData
    }

    // MARK: - URL Parsing

    static func parseRTMPURL(_ urlString: String) -> ParsedURL? {
        guard let components = URLComponents(string: urlString),
              let rawScheme = components.scheme?.lowercased(),
              rawScheme == "rtmp" || rawScheme == "rtmps",
              let host = components.host, !host.isEmpty else {
            return nil
        }

        let port: UInt16
        if let explicitPort = components.port {
            guard explicitPort >= 1 && explicitPort <= Int(UInt16.max) else {
                return nil
            }
            port = UInt16(explicitPort)
        } else {
            port = rawScheme == "rtmps" ? 443 : 1935
        }

        let trimmedPath = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        let app = trimmedPath.isEmpty ? "live" : trimmedPath

        return ParsedURL(scheme: rawScheme, host: host, port: port, app: app)
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
