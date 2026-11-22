import Foundation
import Network
import os
@preconcurrency import AVFoundation
import ArkavoMedia

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
        /// The TCP connection did not become ready within `connectTimeout`.
        /// `lastError` is the most recent error `NWConnection` reported while
        /// `.waiting` (e.g. ECONNREFUSED), if it reported one.
        case connectionTimedOut(seconds: TimeInterval, lastError: NWError?)
        case handshakeFailed
        case publishFailed(String)
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid RTMP URL"
            case .connectionFailed(let reason):
                return "Connection failed: \(reason)"
            case .connectionTimedOut(let seconds, let lastError):
                let base = "Connection timed out after \(Int(seconds))s"
                if let lastError {
                    return "\(base) (last error: \(lastError))"
                }
                return base
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
        public let url: String  // rtmp://server.com/app/streamkey or rtmps://server.com/app
        public let platform: String  // "twitch", "youtube", "custom"

        public init(url: String, platform: String) {
            self.url = url
            self.platform = platform
        }
    }

    struct RTMPURL: Equatable, Sendable {
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

    /// How long `connect(to:streamKey:)` waits for the TCP connection to become
    /// ready before giving up. `NWConnection` reports refused/unreachable hosts
    /// as `.waiting(error)` and retries indefinitely, so this bounds the wait.
    public let connectTimeout: TimeInterval

    // Pending `connect` continuation. Held on the actor so every path that can
    // settle the connect (.ready, .failed, .cancelled, timeout, disconnect)
    // goes through `finishConnect`, which resumes it exactly once.
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var lastWaitingError: NWError?

    // FIFO async lock serializing `sendRTMPMessage` so multi-chunk messages on the
    // same chunk stream cannot interleave across `await sendData(chunk)`.
    private struct SendWaiter {
        let generation: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }
    private var connectionGeneration: UInt64 = 0
    private var isSendingMessage = false
    private var sendWaiters: [SendWaiter] = []

    enum MediaTrack: Sendable {
        case video
        case audio
    }

    /// Maximum clock skew (seconds) between initial video and audio timestamps to
    /// treat them as sharing the same clock domain for A/V lip-sync.
    private static let sharedAnchorMaxSkewSeconds: Double = 10.0

    // Stream configuration
    private var destination: Destination?
    private var streamKey: String?
    private var streamId: UInt32 = 1  // Stream ID from createStream response
    private var transactionId: Double = 0  // Transaction counter for invoke commands (incremented before each use)
    /// Per-track start anchors; shared when both tracks originate in the same clock domain
    /// (<= 10s skew), or independent when clock domains differ (e.g. 0-based video vs host-clock audio).
    private var firstVideoTimestamp: CMTime?
    private var firstAudioTimestamp: CMTime?

    // Statistics
    private var bytesSent: UInt64 = 0
    private var bytesReceived: UInt64 = 0
    private var framesSent: UInt64 = 0
    private var startTime: Date?
    private var windowAckSize: UInt32 = 2500000  // Our window size (what we tell server)
    private var serverWindowAckSize: UInt32 = 250000  // Server's window size (for our acks) - default 250KB
    private var lastAckSent: UInt64 = 0
    private var lastReceivedMessageType: UInt8 = 0  // Track message type from last received chunk
    private var receiveChunkSize: Int = 128  // Current chunk size for receiving (updated by server's SetChunkSize)
    private var sendChunkSize: Int = 4096  // Our chunk size for sending (set via SetChunkSize message)

    // Per-chunk-stream state for RTMP chunk reassembly (handles Types 0/1/2/3, extended timestamps, interleaving)
    // Reference type avoids O(N^2) copy-on-write duplication of `payloadBuffer` across chunks.
    private final class ChunkStreamState {
        var messageLength: UInt32 = 0
        var messageTypeId: UInt8 = 0
        var timestamp: UInt32 = 0
        var timestampDelta: UInt32 = 0
        var remainingBytes: UInt32 = 0
        var hasExtendedTimestamp: Bool = false
        var payloadBuffer: Data = Data()
    }
    private var chunkStreamStates: [UInt32: ChunkStreamState] = [:]

    // Background task for handling server messages
    private var serverMessageTask: Task<Void, Never>?

    // Debug logging control
    private var verboseLogging: Bool = false  // Set to true for detailed frame-by-frame logs
    private var protocolDebugLogging: Bool = false  // Set to true for hex dumps and protocol details
    private var lastSummaryTime: Date?
    private var lastFramesSent: UInt64 = 0

    public var currentState: State {
        state
    }

    /// Enable/disable verbose frame logging (disabled by default to reduce spam)
    public func setVerboseLogging(_ enabled: Bool) {
        verboseLogging = enabled
    }

    /// Enable/disable protocol debug logging with hex dumps (disabled by default)
    /// Useful for debugging RTMP protocol issues with different streaming services
    public func setProtocolDebugLogging(_ enabled: Bool) {
        protocolDebugLogging = enabled
        print("🔧 Protocol debug logging: \(enabled ? "ENABLED" : "DISABLED")")
    }

    /// Log streaming summary every 30 seconds
    private func logStreamingSummary() {
        let now = Date()
        if let lastTime = lastSummaryTime, now.timeIntervalSince(lastTime) < 30.0 {
            return  // Don't log more than once per 30 seconds
        }

        lastSummaryTime = now
        let framesDelta = framesSent - lastFramesSent
        lastFramesSent = framesSent

        if let startTime = startTime {
            let duration = now.timeIntervalSince(startTime)
            let bitrate = calculateBitrate()
            print("📊 Streaming: \(Int(duration))s | \(framesSent) frames | \(framesDelta) frames/30s | \(Int(bitrate/1000)) kbps")
        }
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

    /// - Parameter connectTimeout: Upper bound on how long `connect(to:streamKey:)`
    ///   waits for the TCP connection to become ready. Defaults to 10 seconds.
    public init(connectTimeout: TimeInterval = 10) {
        self.connectTimeout = connectTimeout
    }

    // MARK: - Public Methods

    /// Connect to RTMP server and start publishing.
    ///
    /// Returns once the TCP/TLS connection is up, the RTMP handshake is done and the
    /// `connect`/`createStream`/`publish` exchange has completed. Throws
    /// `RTMPError.connectionTimedOut` if the connection has not become ready
    /// within `connectTimeout` — for example when the host refuses the connection
    /// (`NWConnection` keeps retrying in `.waiting` rather than failing) or is
    /// unreachable — and `RTMPError.connectionFailed` if the connection fails
    /// outright or is cancelled via `disconnect()`.
    public func connect(to destination: Destination, streamKey: String) async throws {
        // Parse RTMP URL first (validating scheme, host, and port 1...65535)
        guard let url = Self.parseRTMPURL(destination.url),
              let nwPort = NWEndpoint.Port(rawValue: url.port) else {
            throw RTMPError.invalidURL
        }

        // Tear down any previous connection/tasks and reset protocol state cleanly
        resetConnectionState(cancelReason: "Superseded by new connect")

        self.destination = destination
        self.streamKey = streamKey

        print("📡 Connecting to \(url.scheme.uppercased()): \(url.host):\(url.port)")

        // Create TCP or TLS connection depending on scheme (rtmp:// vs rtmps://)
        let host = NWEndpoint.Host(url.host)
        let parameters: NWParameters = url.useTLS ? .tls : .tcp

        let newConnection = NWConnection(host: host, port: nwPort, using: parameters)
        connection = newConnection
        connectionGeneration &+= 1

        state = .connecting
        lastWaitingError = nil

        // Start connection. The continuation is settled exactly once by
        // `finishConnect`, from whichever of these fires first: the connection
        // reaching .ready / .failed / .cancelled, or the connect timeout.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation

            // Capture the connection so a late callback from a previous
            // NWConnection can't settle a newer connect attempt.
            newConnection.stateUpdateHandler = { [weak self, weak newConnection] newState in
                Task { [weak self] in
                    await self?.handleConnectionState(newState, from: newConnection)
                }
            }

            let timeout = connectTimeout
            connectTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.connectTimedOut(host: url.host, port: Int(url.port))
            }

            newConnection.start(queue: .global(qos: .userInitiated))
        }

        do {
            // Perform RTMP handshake
            try await performHandshake()

            // Connect to application
            try await connectToApp(url, streamKey: streamKey)
        } catch {
            newConnection.cancel()
            if connection === newConnection {
                connection = nil
                connectionGeneration &+= 1
                failStaleSendWaiters()
                state = .error(error.localizedDescription)
            }
            throw error
        }

        guard connection === newConnection else {
            throw RTMPError.connectionFailed("Connection superseded")
        }

        state = .publishing
        startTime = Date()

        // Start the background server-message handler. The loop reads from the
        // socket and accepts both .publishing and .connected as live states, so
        // server messages issued in the brief window around the state flip
        // can't be missed.
        startServerMessageHandler()

        print("✅ RTMP publishing started")
    }

    /// Normalize a video or audio timestamp relative to the stream start.
    /// Shares a common anchor (`min(timestamp, otherAnchor)`) when video and audio
    /// are in the same clock domain (`abs(delta) <= 10s`) to preserve A/V sync,
    /// and anchors each track independently when clock domains differ (e.g. 0-based
    /// stream-relative video PTS vs host-clock audio PTS).
    func normalizeTimestamp(_ timestamp: CMTime, for track: MediaTrack) -> UInt32 {
        guard timestamp.isNumeric, timestamp.seconds.isFinite else { return 0 }

        let anchor: CMTime
        switch track {
        case .video:
            if let existing = firstVideoTimestamp {
                anchor = existing
            } else if let audioAnchor = firstAudioTimestamp {
                let diff = timestamp - audioAnchor
                let skewSeconds = diff.isNumeric ? abs(diff.seconds) : abs(timestamp.seconds - audioAnchor.seconds)
                if skewSeconds <= Self.sharedAnchorMaxSkewSeconds {
                    let shared = timestamp.seconds < audioAnchor.seconds ? timestamp : audioAnchor
                    firstVideoTimestamp = shared
                    firstAudioTimestamp = shared
                    anchor = shared
                } else {
                    firstVideoTimestamp = timestamp
                    print("📊 Video clock domain differs from audio by \(Int(skewSeconds))s - anchoring video independently at 0ms")
                    return 0
                }
            } else {
                firstVideoTimestamp = timestamp
                print("📊 First video timestamp: \(timestamp.seconds)s - normalizing stream start to 0ms")
                return 0
            }

        case .audio:
            if let existing = firstAudioTimestamp {
                anchor = existing
            } else if let videoAnchor = firstVideoTimestamp {
                let diff = timestamp - videoAnchor
                let skewSeconds = diff.isNumeric ? abs(diff.seconds) : abs(timestamp.seconds - videoAnchor.seconds)
                if skewSeconds <= Self.sharedAnchorMaxSkewSeconds {
                    let shared = timestamp.seconds < videoAnchor.seconds ? timestamp : videoAnchor
                    firstVideoTimestamp = shared
                    firstAudioTimestamp = shared
                    anchor = shared
                } else {
                    firstAudioTimestamp = timestamp
                    print("📊 Audio clock domain differs from video by \(Int(skewSeconds))s - anchoring audio independently at 0ms")
                    return 0
                }
            } else {
                firstAudioTimestamp = timestamp
                print("📊 First audio timestamp: \(timestamp.seconds)s - normalizing stream start to 0ms")
                return 0
            }
        }

        let relativeTime = timestamp - anchor
        let relativeSeconds = relativeTime.isNumeric ? relativeTime.seconds : (timestamp.seconds - anchor.seconds)
        let ms = relativeSeconds * 1000.0
        guard ms.isFinite, ms > 0 else { return 0 }
        if ms >= Double(UInt32.max) {
            return UInt32.max
        }
        return UInt32(ms)
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

        // Process any pending server messages BEFORE sending (like OBS handle_socket_read)
        try await processAllPendingServerMessages()

        // Determine if this is a keyframe (NotSync absent or explicitly false => keyframe)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true

        // Create video payload and send via RTMP message
        let payload = try FLVMuxer.createVideoPayload(sampleBuffer: buffer, isKeyframe: isKeyframe)
        let timestampMs = normalizeTimestamp(timestamp, for: .video)
        try await sendRTMPVideoMessage(data: payload, timestamp: timestampMs)

        framesSent += 1

        // Log summary every 30 seconds
        logStreamingSummary()
    }

    /// Publish video sequence header (AVC/H.264 configuration - SPS/PPS)
    public func publishVideoSequenceHeader(formatDescription: CMFormatDescription) async throws {
        guard state == .publishing else {
            throw RTMPError.notConnected
        }

        // Create video sequence header payload
        let payload = try FLVMuxer.createVideoSequenceHeaderPayload(formatDescription: formatDescription)

        // Send as RTMP message (message type 9 = video, chunk stream 6 for video)
        // Sequence headers must always be sent with timestamp 0 per RTMP spec
        try await sendRTMPVideoMessage(data: payload, timestamp: 0)
        print("✅ Sent video sequence header via RTMP message")
    }

    /// Publish audio sequence header (AAC configuration)
    public func publishAudioSequenceHeader(formatDescription: CMFormatDescription) async throws {
        guard state == .publishing else {
            throw RTMPError.notConnected
        }

        // Create AAC sequence header payload
        let payload = FLVMuxer.createAudioSequenceHeaderPayload(formatDescription: formatDescription)

        // Send as RTMP message (message type 8 = audio, chunk stream 4 for audio)
        // Sequence headers must always be sent with timestamp 0 per RTMP spec
        try await sendRTMPAudioMessage(data: payload, timestamp: 0)
        print("✅ Sent audio sequence header via RTMP message")
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

        // Process any pending server messages BEFORE sending (like OBS handle_socket_read)
        try await processAllPendingServerMessages()

        // Create audio payload and send via RTMP message
        let payload = try FLVMuxer.createAudioPayload(sampleBuffer: buffer)
        let timestampMs = normalizeTimestamp(timestamp, for: .audio)
        try await sendRTMPAudioMessage(data: payload, timestamp: timestampMs)
    }

    // MARK: - Simplified API for EncodedFrames

    /// Send encoded video frame
    public func send(video frame: EncodedVideoFrame) async throws {
        guard state == .publishing else {
            throw RTMPError.notConnected
        }

        guard let connection = connection, connection.state == .ready else {
            throw RTMPError.connectionFailed("Connection not ready")
        }

        // Create video payload from encoded frame
        let payload = FLVMuxer.createVideoPayload(from: frame)
        let timestampMs = normalizeTimestamp(frame.pts, for: .video)
        try await sendRTMPVideoMessage(data: payload, timestamp: timestampMs)

        framesSent += 1
    }

    /// Send encoded audio frame
    public func send(audio frame: EncodedAudioFrame) async throws {
        guard state == .publishing else {
            throw RTMPError.notConnected
        }

        guard let connection = connection, connection.state == .ready else {
            throw RTMPError.connectionFailed("Connection not ready")
        }

        // Create audio payload from encoded frame
        let payload = FLVMuxer.createAudioPayload(from: frame)
        let timestampMs = normalizeTimestamp(frame.pts, for: .audio)
        try await sendRTMPAudioMessage(data: payload, timestamp: timestampMs)
    }

    /// Send video sequence header (SPS/PPS)
    public func sendVideoSequenceHeader(formatDescription: CMVideoFormatDescription) async throws {
        guard state == .publishing else {
            throw RTMPError.notConnected
        }

        // Create video sequence header payload
        let payload = try FLVMuxer.createVideoSequenceHeader(from: formatDescription)

        // Send as RTMP message (timestamp 0 for sequence headers)
        try await sendRTMPVideoMessage(data: payload, timestamp: 0)
        print("✅ Sent video sequence header")
    }

    /// Send audio sequence header (AudioSpecificConfig)
    public func sendAudioSequenceHeader(asc: Data) async throws {
        guard state == .publishing else {
            throw RTMPError.notConnected
        }

        // Create AAC sequence header payload
        let payload = FLVMuxer.createAudioSequenceHeader(asc: asc)

        // Send as RTMP message (timestamp 0 for sequence headers)
        try await sendRTMPAudioMessage(data: payload, timestamp: 0)
        print("✅ Sent audio sequence header")
    }

    /// Send raw video data payload (for special frames like NTDF header)
    /// - Parameters:
    ///   - payload: Raw video payload (already formatted with FLV video header)
    ///   - timestamp: Timestamp in milliseconds
    public func sendRawVideoData(_ payload: Data, timestamp: UInt32) async throws {
        guard state == .publishing else {
            throw RTMPError.notConnected
        }
        try await sendRTMPVideoMessage(data: payload, timestamp: timestamp)
    }

    /// Send stream metadata (@setDataFrame onMetaData)
    /// - Parameters:
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    ///   - framerate: Video framerate (fps)
    ///   - videoBitrate: Video bitrate in bits/sec
    ///   - audioBitrate: Audio bitrate in bits/sec
    ///   - customFields: Optional custom string fields (e.g., ntdf_header for NanoTDF encryption)
    public func sendMetadata(
        width: Int,
        height: Int,
        framerate: Double,
        videoBitrate: Double,
        audioBitrate: Double,
        customFields: [String: String]? = nil
    ) async throws {
        guard state == .publishing else {
            throw RTMPError.notConnected
        }

        // Create AMF0-encoded metadata message
        let payload = FLVMuxer.createMetadata(
            width: width,
            height: height,
            framerate: framerate,
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate,
            customFields: customFields
        )

        // Send as RTMP Script Data message (type 18, timestamp 0)
        try await sendRTMPMessage(
            chunkStreamId: 5,  // Data/metadata chunk stream
            messageTypeId: 18,  // AMF0 Script Data
            messageStreamId: streamId,
            payload: payload,
            timestamp: 0
        )
        print("✅ Sent stream metadata (\(width)x\(height) @\(framerate)fps)")
    }

    /// Disconnect from server
    public func disconnect() async {
        print("📡 Disconnecting RTMP...")

        // Send proper RTMP shutdown commands if currently publishing
        if state == .publishing {
            do {
                // Send FCUnpublish (Twitch-specific, optional)
                if let key = streamKey {
                    try await sendFCUnpublish(streamKey: key)
                }

                // Send deleteStream command
                try await sendDeleteStream(streamId: streamId)

                // Give server a moment to process shutdown commands
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            } catch {
                print("⚠️ Error during graceful shutdown: \(error)")
                // Continue with disconnect anyway
            }
        }

        resetConnectionState(cancelReason: "Cancelled")
        print("✅ RTMP disconnected gracefully")
    }

    private func resetConnectionState(cancelReason: String) {
        if let task = serverMessageTask {
            print("🛑 Cancelling background server message handler task...")
            task.cancel()
            serverMessageTask = nil
        }

        finishConnect(.failure(RTMPError.connectionFailed(cancelReason)))

        if let existingConnection = connection {
            existingConnection.cancel()
        }
        connection = nil
        connectionGeneration &+= 1
        failStaleSendWaiters()
        state = .disconnected
        isHandshakeComplete = false
        bytesSent = 0
        bytesReceived = 0
        framesSent = 0
        startTime = nil
        firstVideoTimestamp = nil
        firstAudioTimestamp = nil
        receiveChunkSize = 128
        sendChunkSize = 4096
        serverWindowAckSize = 250000
        lastAckSent = 0
        lastReceivedMessageType = 0
        streamId = 1
        transactionId = 0
        lastSummaryTime = nil
        lastFramesSent = 0
        chunkStreamStates.removeAll()
    }

    // MARK: - URL Parsing

    static func parseRTMPURL(_ urlString: String) -> RTMPURL? {
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

        let pathParts = components.path.split(separator: "/").map(String.init)
        let app = pathParts.first ?? "live"

        return RTMPURL(scheme: rawScheme, host: host, port: port, app: app)
    }

    // MARK: - Send Serialization

    private func acquireSendLock(for generation: UInt64) async throws {
        guard connectionGeneration == generation else {
            throw RTMPError.notConnected
        }
        if !isSendingMessage {
            isSendingMessage = true
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendWaiters.append(SendWaiter(generation: generation, continuation: continuation))
        }
    }

    private func releaseSendLock() {
        while !sendWaiters.isEmpty {
            let next = sendWaiters.removeFirst()
            if next.generation == connectionGeneration {
                next.continuation.resume()
                return
            } else {
                next.continuation.resume(throwing: RTMPError.notConnected)
            }
        }
        isSendingMessage = false
    }

    private func failStaleSendWaiters() {
        var liveWaiters: [SendWaiter] = []
        var staleWaiters: [SendWaiter] = []
        for waiter in sendWaiters {
            if waiter.generation == connectionGeneration {
                liveWaiters.append(waiter)
            } else {
                staleWaiters.append(waiter)
            }
        }
        sendWaiters = liveWaiters
        for waiter in staleWaiters {
            waiter.continuation.resume(throwing: RTMPError.notConnected)
        }
    }

    // MARK: - Connection Lifecycle

    /// Resumes the pending `connect` continuation exactly once and stops the
    /// connect timeout. Later calls (a `.cancelled` callback after the timeout
    /// already fired, a `.failed` after `disconnect()`, ...) are no-ops.
    private func finishConnect(_ result: Result<Void, Error>) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil

        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume(with: result)
    }

    /// Fired by the connect timeout task when the TCP connection has not become
    /// ready within `connectTimeout`.
    private func connectTimedOut(host: String, port: Int) {
        guard connectContinuation != nil else { return }

        let error = RTMPError.connectionTimedOut(seconds: connectTimeout, lastError: lastWaitingError)
        print("❌ Connection to \(host):\(port) timed out after \(Int(connectTimeout))s (last error: \(lastWaitingError.map { "\($0)" } ?? "none"))")
        state = .error(error.localizedDescription)

        // Cancel the socket so NWConnection stops retrying. The resulting
        // .cancelled callback is ignored: the continuation is already gone and
        // `connection` no longer matches.
        connection?.cancel()
        connection = nil
        connectionGeneration &+= 1
        failStaleSendWaiters()

        finishConnect(.failure(error))
    }

    private func handleConnectionState(_ newState: NWConnection.State, from source: NWConnection?) {
        // Ignore callbacks from a connection this publisher no longer owns
        // (cancelled by the timeout, replaced by a newer connect, or torn down).
        guard let source, source === connection else {
            print("⚠️ Ignoring state \(newState) from a stale connection")
            return
        }

        switch newState {
        case .ready:
            print("✅ TCP connection established")
            state = .connected
            finishConnect(.success(()))
        case .failed(let error):
            // "\(error)" gives e.g. "POSIXErrorCode(rawValue: 61): Connection refused";
            // NWError is not LocalizedError, so localizedDescription is generic.
            let errorMsg = "\(error)"
            print("❌ Connection failed: \(errorMsg)")
            // As before, a failure after connect has settled is only logged;
            // the publish methods surface it via their own connection checks.
            guard connectContinuation != nil else { return }
            state = .error(errorMsg)
            finishConnect(.failure(RTMPError.connectionFailed(errorMsg)))
        case .waiting(let error):
            // NWConnection stays here and retries on ECONNREFUSED / no route.
            // Remember the error so the connect timeout can report it.
            print("⏳ Connection waiting: \(error)")
            lastWaitingError = error
        case .cancelled:
            print("🚫 Connection cancelled")
            guard connectContinuation != nil else { return }
            finishConnect(.failure(RTMPError.connectionFailed("Cancelled")))
        default:
            break
        }
    }

    private func performHandshake() async throws {
        let gen = connectionGeneration
        guard let targetConnection = connection else {
            throw RTMPError.notConnected
        }

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
        try await sendData(c0 + c1, expectedGeneration: gen, expectedConnection: targetConnection)

        // Receive S0 + S1 + S2 (must receive all 3073 bytes)
        let handshakeTimeout = Duration.seconds(max(5, connectTimeout))
        let responseLength = 1 + 1536 + 1536
        guard let response = try await receiveDataExact(length: responseLength, timeout: handshakeTimeout),
              response.count == responseLength else {
            throw RTMPError.handshakeFailed
        }

        print("✅ Received handshake response: \(response.count) bytes")

        // Validate S0
        guard response[0] == 0x03 else {
            throw RTMPError.handshakeFailed
        }

        // Send C2 (echo of S1)
        let s1 = response.subdata(in: 1..<1537)
        try await sendData(s1, expectedGeneration: gen, expectedConnection: targetConnection)

        isHandshakeComplete = true
        print("✅ RTMP handshake complete")
    }

    private func applySetChunkSize(_ messageData: Data) throws {
        guard messageData.count >= 4 else { return }
        let rawSize = (UInt32(messageData[0]) << 24 | UInt32(messageData[1]) << 16 |
                       UInt32(messageData[2]) << 8 | UInt32(messageData[3])) & 0x7FFF_FFFF
        guard rawSize > 0 else {
            throw RTMPError.connectionFailed("Invalid server SetChunkSize: 0")
        }
        receiveChunkSize = Int(rawSize)
        print("📥 Server Set Chunk Size: \(rawSize) (updated receiveChunkSize)")
    }

    private func connectToApp(_ url: RTMPURL, streamKey: String) async throws {
        let app = url.app
        print("📡 Connecting to app: \(app)")

        let controlTimeout = Duration.seconds(max(5, connectTimeout))

        // Send SetChunkSize message
        var chunkSizeData = Data()
        let newChunkSize: UInt32 = 4096  // Moderate chunk size for reliability
        chunkSizeData.append(contentsOf: newChunkSize.bigEndianBytes)

        try await sendRTMPMessage(
            chunkStreamId: 2,
            messageTypeId: 1,  // Set Chunk Size
            messageStreamId: 0,
            payload: chunkSizeData
        )
        sendChunkSize = Int(newChunkSize)
        print("✅ Sent SetChunkSize: \(newChunkSize)")

        // Send Window Acknowledgement Size to inform server of our window size
        var windowAckData = Data()
        let clientWindowSize: UInt32 = 2500000  // 2.5MB window
        windowAckData.append(contentsOf: clientWindowSize.bigEndianBytes)

        try await sendRTMPMessage(
            chunkStreamId: 2,
            messageTypeId: 5,  // Window Acknowledgement Size
            messageStreamId: 0,
            payload: windowAckData
        )
        print("✅ Sent Window Acknowledgement Size: \(clientWindowSize)")

        // Reset transaction counter for new connection
        transactionId = 0

        // Create RTMP connect command (transaction ID 1)
        transactionId += 1  // = 1
        let connectCommand = AMF0.createConnectCommand(
            app: app,
            tcUrl: url.tcUrl
        )

        print("📤 Sending connect command (txnId=\(transactionId)): \(connectCommand.count) bytes")
        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,  // AMF0 command
            messageStreamId: 0,
            payload: connectCommand
        )

        print("✅ Connect command sent")

        // Wait for connect _result (txnId 1) or _error
        print("⏳ Waiting for connect response...")
        var receivedConnectResult = false
        for _ in 0..<25 {
            let (messageType, messageData, messageBytes) = try await receiveRTMPMessage(timeout: controlTimeout)
            bytesReceived += UInt64(messageBytes)

            switch messageType {
            case 1:  // Set Chunk Size
                try applySetChunkSize(messageData)
            case 4:  // User Control
                try await handleUserControlMessage(messageData)
            case 5:  // Window Acknowledgement Size
                if messageData.count >= 4 {
                    serverWindowAckSize = UInt32(messageData[0]) << 24 | UInt32(messageData[1]) << 16 |
                                         UInt32(messageData[2]) << 8 | UInt32(messageData[3])
                    print("📥 Server Window Ack Size: \(serverWindowAckSize)")
                }
            case 6:  // Set Peer Bandwidth
                print("📥 Server Set Peer Bandwidth")
            case 20:  // AMF0 Command
                let (cmdName, cmdTxnId) = parseAMFCommandHeader(messageData)
                if cmdName == "_error" {
                    let errorReason = parseAMFError(messageData) ?? "Connection rejected by server"
                    print("❌ RTMP connect rejected: \(errorReason)")
                    throw RTMPError.connectionFailed(errorReason)
                }
                if cmdName == "_result", cmdTxnId == 1.0 {
                    receivedConnectResult = true
                } else {
                    print("📥 Connect phase: ignoring AMF0 command '\(cmdName ?? "unknown")' (txnId=\(cmdTxnId.map { String($0) } ?? "nil"))")
                }
            default:
                print("📥 Connect phase: received message type \(messageType)")
            }

            if receivedConnectResult {
                break
            }
        }

        guard receivedConnectResult else {
            throw RTMPError.connectionFailed("Did not receive connect _result from server")
        }
        print("✅ Received connect response")

        // Release stream (transaction ID 2)
        transactionId += 1  // = 2
        let releaseStreamCommand = AMF0.createReleaseStreamCommand(streamName: streamKey, transactionId: transactionId)
        print("📤 Sending releaseStream command (txnId=\(transactionId))")
        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,
            messageStreamId: 0,
            payload: releaseStreamCommand
        )

        // FCPublish (transaction ID 3)
        transactionId += 1  // = 3
        let fcPublishCommand = AMF0.createFCPublishCommand(streamName: streamKey, transactionId: transactionId)
        print("📤 Sending FCPublish command (txnId=\(transactionId))")
        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,
            messageStreamId: 0,
            payload: fcPublishCommand
        )

        // CreateStream (transaction ID 4)
        transactionId += 1  // = 4
        let createStreamCommand = AMF0.createCreateStreamCommand(transactionId: transactionId)
        print("📤 Sending createStream command (txnId=\(transactionId))")
        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,
            messageStreamId: 0,
            payload: createStreamCommand
        )

        print("✅ CreateStream command sent, waiting for stream ID...")

        // Wait for createStream _result response (transaction ID 4)
        var receivedStreamId = false
        responseLoop: for _ in 0..<25 {
            let (messageType, messageData, messageBytes) = try await receiveRTMPMessage(timeout: controlTimeout)
            bytesReceived += UInt64(messageBytes)

            switch messageType {
            case 1:  // Set Chunk Size
                try applySetChunkSize(messageData)
            case 4:  // User Control
                try await handleUserControlMessage(messageData)
            case 5:  // Window Acknowledgement Size
                if messageData.count >= 4 {
                    serverWindowAckSize = UInt32(messageData[0]) << 24 | UInt32(messageData[1]) << 16 |
                                         UInt32(messageData[2]) << 8 | UInt32(messageData[3])
                    print("📥 Server Window Ack Size: \(serverWindowAckSize) (processed during createStream wait)")
                }
            case 6:  // Set Peer Bandwidth
                print("📥 Server Set Peer Bandwidth (processed during createStream wait)")
            case 20:  // AMF0 Command
                let (cmdName, cmdTxnId) = parseAMFCommandHeader(messageData)
                if cmdName == "_error", cmdTxnId == 4.0 {
                    let reason = parseAMFError(messageData) ?? "createStream rejected by server"
                    throw RTMPError.publishFailed(reason)
                }
                if let parsedStreamId = try? parseCreateStreamResponse(messageData) {
                    streamId = parsedStreamId
                    print("✅ Received stream ID from _result: \(streamId)")
                    receivedStreamId = true
                    break responseLoop
                }
                print("📥 Skipping AMF message '\(cmdName ?? "unknown")' (not createStream _result)")
            default:
                print("📥 Skipping message type \(messageType) while waiting for createStream response")
            }
        }

        guard receivedStreamId else {
            throw RTMPError.publishFailed("Did not receive createStream _result from server")
        }

        // Send publish command to start streaming (transaction ID 5)
        transactionId += 1  // = 5
        print("📤 Preparing to send publish command with streamKey=\(streamKey) streamId=\(streamId) txnId=\(transactionId)")
        let publishCommand = AMF0.createPublishCommand(
            streamName: streamKey,
            publishingName: "live",
            transactionId: transactionId
        )
        print("📤 Publish command created, payload size: \(publishCommand.count) bytes")
        try await sendRTMPMessage(
            chunkStreamId: 4,  // OBS uses 0x04 for publish (source channel), not 0x03
            messageTypeId: 20,
            messageStreamId: streamId,
            payload: publishCommand
        )

        print("✅ Publish command sent (txnId=\(transactionId)), waiting for publish status...")

        // Wait for explicit onStatus NetStream.Publish.Start (or error/denial)
        var receivedPublishStatus = false
        for _ in 0..<25 {
            let (messageType, messageData, messageBytes) = try await receiveRTMPMessage(timeout: controlTimeout)
            bytesReceived += UInt64(messageBytes)

            switch messageType {
            case 1:  // Set Chunk Size
                try applySetChunkSize(messageData)
            case 4:  // User Control
                try await handleUserControlMessage(messageData)
            case 5:  // Window Acknowledgement Size
                if messageData.count >= 4 {
                    serverWindowAckSize = UInt32(messageData[0]) << 24 | UInt32(messageData[1]) << 16 |
                                         UInt32(messageData[2]) << 8 | UInt32(messageData[3])
                }
            case 6:  // Set Peer Bandwidth
                print("📥 Server Set Peer Bandwidth (during publish wait)")
            case 20:  // AMF0 Command
                let statusInfo = parsePublishStatus(messageData)
                if let denied = statusInfo.error {
                    print("❌ Publish denied: \(denied)")
                    throw RTMPError.publishFailed(denied)
                }
                if statusInfo.isPublishStart {
                    print("✅ Publish status: \(statusInfo.status ?? "NetStream.Publish.Start")")
                    receivedPublishStatus = true
                } else {
                    print("📥 Publish phase: ignoring non-start AMF0 command (status: \(statusInfo.status ?? "none"))")
                }
            default:
                print("📥 Publish phase: received message type \(messageType)")
            }

            if receivedPublishStatus { break }
        }

        guard receivedPublishStatus else {
            throw RTMPError.publishFailed("Did not receive NetStream.Publish.Start from server")
        }

        print("✅ App connection complete, ready to stream")
    }

    private func parseAMFCommandHeader(_ data: Data) -> (name: String?, transactionId: Double?) {
        var parser = AMF0Parser(data: data)
        let name = (try? parser.readValue())?.stringValue
        let txnId = (try? parser.readValue())?.numberValue
        return (name, txnId)
    }

    /// Recursively extract all strings from an AMF0 value (bounded recursion depth)
    private func extractStrings(from value: AMF0Parser.Value, into strings: inout [String], depth: Int = 0) {
        guard depth < AMF0Parser.maxDepth else { return }
        switch value {
        case .string(let str):
            strings.append(str)
        case .object(let dict):
            for (key, val) in dict {
                strings.append(key)
                extractStrings(from: val, into: &strings, depth: depth + 1)
            }
        case .array(let arr):
            for val in arr {
                extractStrings(from: val, into: &strings, depth: depth + 1)
            }
        default:
            break
        }
    }

    /// Parse an AMF0 response for _error command. Returns an error reason string if found.
    private func parseAMFError(_ data: Data) -> String? {
        var parser = AMF0Parser(data: data)
        do {
            let values = try parser.readAllValues()
            guard values.first?.stringValue == "_error" else {
                return nil
            }
            for value in values.dropFirst() {
                if case .object(let dict) = value {
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
            var strings: [String] = []
            for value in values {
                extractStrings(from: value, into: &strings)
            }
            let code = strings.first(where: { $0.hasPrefix("NetConnection.Connect.") && $0 != "NetConnection.Connect.Success" })
            return code ?? "Connection rejected by server"
        } catch {
            return nil
        }
    }

    /// Parse a publish AMF0 response strictly inspecting command name and status code.
    private func parsePublishStatus(_ data: Data) -> (status: String?, error: String?, isPublishStart: Bool) {
        var parser = AMF0Parser(data: data)
        do {
            let values = try parser.readAllValues()
            guard let commandName = values.first?.stringValue else {
                return (nil, nil, false)
            }

            if commandName == "_error" {
                let reason = parseAMFError(data) ?? "Publish rejected by server"
                return (nil, reason, false)
            }

            guard commandName == "onStatus" else {
                // Ignore unrelated notifications such as onFCPublish, onBWDone, or prior _result
                return (commandName, nil, false)
            }

            // Standard onStatus layout: ["onStatus", 0.0, null, {level: ..., code: ..., description: ...}]
            let infoDict = values.dropFirst().compactMap { $0.objectValue }.first
            let code = infoDict?["code"]?.stringValue
            let level = infoDict?["level"]?.stringValue
            let description = infoDict?["description"]?.stringValue

            if code == "NetStream.Publish.Denied" {
                return (nil, description ?? "Stream publishing denied. Your account may not meet the platform's streaming requirements.", false)
            }
            if code == "NetStream.Failed" || code == "NetStream.Publish.BadName" || code == "NetStream.Publish.Rejected" {
                return (nil, description ?? code ?? "Stream key is invalid or stream publishing failed.", false)
            }
            if level == "error" {
                return (nil, description ?? code ?? "Stream rejected by server.", false)
            }
            if code == "NetStream.Publish.Start" {
                return (code, nil, true)
            }

            return (code, nil, false)
        } catch {
            return (nil, nil, false)
        }
    }

    /// Handle User Control Messages (type 4)
    /// Format: 2 bytes event type + event data
    private func handleUserControlMessage(_ data: Data) async throws {
        guard data.count >= 2 else {
            print("📥 Invalid User Control Message: too short")
            return
        }

        let eventType = UInt16(data[0]) << 8 | UInt16(data[1])

        switch eventType {
        case 0: // Stream Begin
            if data.count >= 6 {
                let receivedStreamId = UInt32(data[2]) << 24 | UInt32(data[3]) << 16 |
                              UInt32(data[4]) << 8 | UInt32(data[5])
                print("📥 User Control: Stream Begin (stream ID: \(receivedStreamId))")
            }

        case 1: // Stream EOF
            print("📥 User Control: Stream EOF")

        case 2: // Stream Dry
            print("📥 User Control: Stream Dry")

        case 3: // SetBufferLength
            if data.count >= 10 {
                let receivedStreamId = UInt32(data[2]) << 24 | UInt32(data[3]) << 16 |
                              UInt32(data[4]) << 8 | UInt32(data[5])
                let bufferLength = UInt32(data[6]) << 24 | UInt32(data[7]) << 16 |
                                  UInt32(data[8]) << 8 | UInt32(data[9])
                print("📥 User Control: SetBufferLength (stream: \(receivedStreamId), buffer: \(bufferLength)ms)")
            }

        case 6: // Ping Request
            if data.count >= 6 {
                let timestamp = UInt32(data[2]) << 24 | UInt32(data[3]) << 16 |
                               UInt32(data[4]) << 8 | UInt32(data[5])
                print("🏓 📥 PING REQUEST from server (timestamp: \(timestamp)) - sending Pong response...")
                try await sendPongResponse(timestamp: timestamp)
                print("🏓 ✅ Pong response sent successfully")
            }

        case 7: // Ping Response (Pong)
            if data.count >= 6 {
                let timestamp = UInt32(data[2]) << 24 | UInt32(data[3]) << 16 |
                               UInt32(data[4]) << 8 | UInt32(data[5])
                print("📥 User Control: Pong Response (timestamp: \(timestamp))")
            }

        default:
            print("📥 User Control: Unknown event type \(eventType)")
        }
    }

    /// Send Pong Response to server's Ping Request
    private func sendPongResponse(timestamp: UInt32) async throws {
        var pongData = Data()
        pongData.append(contentsOf: [0x00, 0x07])
        pongData.append(contentsOf: timestamp.bigEndianBytes)

        try await sendRTMPMessage(
            chunkStreamId: 2,
            messageTypeId: 4,  // User Control Message
            messageStreamId: 0,
            payload: pongData
        )
    }

    /// Send Window Acknowledgement message to server
    private func sendWindowAcknowledgement(bytesReceived: UInt32) async throws {
        var ackData = Data()
        ackData.append(contentsOf: bytesReceived.bigEndianBytes)

        try await sendRTMPMessage(
            chunkStreamId: 2,
            messageTypeId: 3,  // Acknowledgement (bytes received report)
            messageStreamId: 0,
            payload: ackData
        )
        print("✅ Sent Window Acknowledgement: \(bytesReceived) bytes")
    }

    /// Send FCUnpublish command (Twitch-specific graceful shutdown)
    private func sendFCUnpublish(streamKey: String) async throws {
        transactionId += 1
        let command = AMF0.createFCUnpublishCommand(streamName: streamKey, transactionId: transactionId)

        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,  // AMF0 command
            messageStreamId: 0,
            payload: command
        )
        print("📤 Sent FCUnpublish command (txnId=\(transactionId))")
    }

    /// Send deleteStream command (proper RTMP stream cleanup)
    private func sendDeleteStream(streamId: UInt32) async throws {
        transactionId += 1
        let command = AMF0.createDeleteStreamCommand(streamId: streamId, transactionId: transactionId)

        try await sendRTMPMessage(
            chunkStreamId: 3,
            messageTypeId: 20,  // AMF0 command
            messageStreamId: 0,
            payload: command
        )
        print("📤 Sent deleteStream command (streamId=\(streamId), txnId=\(transactionId))")
    }

    /// Send RTMP chunk message (serialized via FIFO lock so multi-chunk messages never interleave).
    /// Supports RTMP extended timestamps (`timestamp >= 0xFFFFFF`) on both Type 0 and Type 3 chunks.
    private func sendRTMPMessage(
        chunkStreamId: UInt8,
        messageTypeId: UInt8,
        messageStreamId: UInt32,
        payload: Data,
        timestamp: UInt32 = 0
    ) async throws {
        let gen = connectionGeneration
        guard let targetConnection = connection else {
            throw RTMPError.notConnected
        }

        try await acquireSendLock(for: gen)
        defer { releaseSendLock() }

        guard connectionGeneration == gen, self.connection === targetConnection else {
            throw RTMPError.notConnected
        }

        let normalizedPayload = payload.startIndex == 0 ? payload : Data(payload)
        let messageLength = UInt32(normalizedPayload.count)
        let hasExtendedTimestamp = timestamp >= 0xFF_FFFF
        let headerTimestamp: UInt32 = hasExtendedTimestamp ? 0xFF_FFFF : timestamp

        // Build Type 0 header (1-byte basic header + 11-byte message header + optional 4-byte ext timestamp)
        var header = Data()
        header.append(chunkStreamId & 0x3F)

        // Timestamp (3 bytes, or 0xFFFFFF when extended)
        header.append(UInt8((headerTimestamp >> 16) & 0xFF))
        header.append(UInt8((headerTimestamp >> 8) & 0xFF))
        header.append(UInt8(headerTimestamp & 0xFF))

        // Message length (3 bytes)
        header.append(UInt8((messageLength >> 16) & 0xFF))
        header.append(UInt8((messageLength >> 8) & 0xFF))
        header.append(UInt8(messageLength & 0xFF))

        // Message type ID (1 byte)
        header.append(messageTypeId)

        // Message stream ID (4 bytes, little endian)
        var streamIdLE = messageStreamId.littleEndian
        header.append(Data(bytes: &streamIdLE, count: 4))

        // Extended timestamp (4 bytes big-endian) if timestamp >= 0xFFFFFF
        if hasExtendedTimestamp {
            header.append(contentsOf: timestamp.bigEndianBytes)
        }

        if normalizedPayload.isEmpty {
            try await sendData(header, expectedGeneration: gen, expectedConnection: targetConnection)
            return
        }

        // Split payload into chunks and send atomically while holding the send lock
        var offset = 0
        var chunkCount = 0

        while offset < normalizedPayload.count {
            let remaining = normalizedPayload.count - offset
            let chunkSize = min(remaining, sendChunkSize)

            var chunk = Data()
            let fmt: UInt8

            if chunkCount == 0 {
                // First chunk: Type 0 header + data
                fmt = 0
                chunk.append(header)
                chunk.append(normalizedPayload[offset..<(offset + chunkSize)])

                if protocolDebugLogging && (messageTypeId == 8 || messageTypeId == 9) {
                    let headerHex = header.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("📤 Type 0 header: \(headerHex) (csid=\(chunkStreamId) type=\(messageTypeId) len=\(messageLength))")
                }
            } else {
                // Continuation chunks: Type 3 header (1 byte) + optional 4-byte extended timestamp + data
                fmt = 3
                let continuationHeader = 0xC0 | (chunkStreamId & 0x3F)
                chunk.append(continuationHeader)
                if hasExtendedTimestamp {
                    chunk.append(contentsOf: timestamp.bigEndianBytes)
                }
                chunk.append(normalizedPayload[offset..<(offset + chunkSize)])

                if protocolDebugLogging && chunkCount == 1 {
                    print("📤 Type 3 continuation: 0x\(String(format: "%02X", continuationHeader)) (csid=\(chunkStreamId))")
                }
            }

            if verboseLogging && normalizedPayload.count > sendChunkSize {
                print("📤 Chunk[\(chunkCount)]: fmt=\(fmt) csid=\(chunkStreamId) dataLen=\(chunkSize) offset=\(offset) totalPayload=\(normalizedPayload.count)")
            }

            try await sendData(chunk, expectedGeneration: gen, expectedConnection: targetConnection)

            offset += chunkSize
            chunkCount += 1
        }

        // Only log control messages (types 1-6), not audio/video frames
        let isControlMessage = messageTypeId < 8
        if isControlMessage {
            if chunkCount > 1 {
                print("📤 RTMP message chunked: type=\(messageTypeId) csid=\(chunkStreamId) ts=\(timestamp) payloadLen=\(normalizedPayload.count) chunks=\(chunkCount) chunkSize=\(sendChunkSize)")
            } else {
                print("📤 RTMP message: type=\(messageTypeId) csid=\(chunkStreamId) ts=\(timestamp) payloadLen=\(normalizedPayload.count)")
            }
        }
    }

    /// Send video data as RTMP message (type 9)
    private func sendRTMPVideoMessage(data: Data, timestamp: UInt32) async throws {
        if framesSent == 0 || framesSent % 900 == 0 {
            print("📤 [RTMPPub] video #\(framesSent): \(data.count)B ts=\(timestamp)")
        }
        try await sendRTMPMessage(
            chunkStreamId: 6,  // Video chunk stream (must be different from audio)
            messageTypeId: 9,  // Video message
            messageStreamId: streamId,
            payload: data,
            timestamp: timestamp
        )
    }

    /// Send audio data as RTMP message (type 8)
    private func sendRTMPAudioMessage(data: Data, timestamp: UInt32) async throws {
        try await sendRTMPMessage(
            chunkStreamId: 4,  // Audio chunk stream (must be different from video)
            messageTypeId: 8,  // Audio message
            messageStreamId: streamId,
            payload: data,
            timestamp: timestamp
        )
    }

    /// Send raw data packet to RTMP stream, verified against the caller's connection generation.
    private func sendData(
        _ data: Data,
        expectedGeneration: UInt64,
        expectedConnection: NWConnection
    ) async throws {
        guard connectionGeneration == expectedGeneration,
              let currentConnection = connection,
              currentConnection === expectedConnection else {
            throw RTMPError.notConnected
        }

        guard currentConnection.state == .ready else {
            state = .error("Connection not ready")
            throw RTMPError.connectionFailed("Connection state: \(currentConnection.state)")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            currentConnection.send(content: data, completion: .contentProcessed { [weak self, weak expectedConnection] error in
                if let error = error {
                    Task { [weak self] in
                        await self?.handleSendError(error, from: expectedGeneration, connection: expectedConnection)
                    }
                    continuation.resume(throwing: RTMPError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }

        if connectionGeneration == expectedGeneration && connection === expectedConnection {
            bytesSent += UInt64(data.count)
        }
    }

    private func handleSendError(_ error: Error, from generation: UInt64, connection source: NWConnection?) {
        guard connectionGeneration == generation, let source, connection === source else {
            return
        }
        state = .error("Send failed: \(error.localizedDescription)")
        print("❌ RTMP send error: \(error)")
    }

    /// Receive RTMP message and return (messageType, payload, totalBytes)
    private func receiveRTMPMessage(timeout: Duration? = .seconds(5)) async throws -> (UInt8, Data, Int) {
        let (payload, totalBytes) = try await receiveRTMPChunk(firstByteTimeout: timeout)
        return (lastReceivedMessageType, payload, totalBytes)
    }

    /// Start background task to read and handle server messages during streaming
    /// (ping requests, ack requests, user control messages, etc.)
    private func startServerMessageHandler() {
        serverMessageTask = Task { [weak self] in
            guard let self = self else { return }
            print("📡 Server message handler started")
            while !Task.isCancelled {
                do {
                    let connState = await self.state
                    guard connState == .publishing || connState == .connected else { break }
                    // Wait indefinitely for next incoming server message (cancellable on disconnect),
                    // while enforcing deadlines once the first byte of a message arrives.
                    let (messageType, messageData, messageBytes) = try await self.receiveRTMPMessage(timeout: nil)
                    await self.addBytesReceived(UInt64(messageBytes))

                    switch messageType {
                    case 1: // Set Chunk Size
                        try await self.applySetChunkSize(messageData)
                    case 3: // Acknowledgement
                        print("📥 [BG] Server Acknowledgement")
                    case 4: // User Control (includes ping)
                        try await self.handleUserControlMessage(messageData)
                    case 5: // Window Acknowledgement Size
                        if messageData.count >= 4 {
                            let size = UInt32(messageData[0]) << 24 | UInt32(messageData[1]) << 16 |
                                      UInt32(messageData[2]) << 8 | UInt32(messageData[3])
                            await self.setServerWindowAckSize(size)
                            print("📥 [BG] Server Window Ack Size: \(size)")
                        }
                    case 6: // Set Peer Bandwidth
                        print("📥 [BG] Server Set Peer Bandwidth")
                    case 20: // AMF0 Command
                        print("📥 [BG] Server AMF0 command (ignored during streaming)")
                    default:
                        print("📥 [BG] Server message type \(messageType) (\(messageData.count) bytes)")
                    }

                    // Send acknowledgement if we've received enough bytes
                    let received = await self.getBytesReceived()
                    let ackSize = await self.getServerWindowAckSize()
                    let lastAck = await self.getLastAckSent()
                    if ackSize > 0 && received - lastAck >= UInt64(ackSize) {
                        try await self.sendWindowAcknowledgement(bytesReceived: UInt32(truncatingIfNeeded: received))
                        await self.setLastAckSent(received)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if !Task.isCancelled {
                        print("⚠️ [BG] Server message handler error: \(error.localizedDescription)")
                    }
                    break
                }
            }
            print("📡 Server message handler stopped")
        }
    }

    // Actor-isolated accessors for server message handler
    private func addBytesReceived(_ bytes: UInt64) { bytesReceived += bytes }
    private func getBytesReceived() -> UInt64 { bytesReceived }
    private func getServerWindowAckSize() -> UInt32 { serverWindowAckSize }
    private func setServerWindowAckSize(_ size: UInt32) { serverWindowAckSize = size }
    private func getLastAckSent() -> UInt64 { lastAckSent }
    private func setLastAckSent(_ value: UInt64) { lastAckSent = value }

    /// Server messages are handled by the background handler (startServerMessageHandler).
    private func processAllPendingServerMessages() async throws {
        // No-op: background handler processes server messages via blocking receive.
    }

    /// Receive and reassemble a complete RTMP message from one or more chunks.
    /// Supports 1/2/3-byte chunk stream IDs (`UInt32`), extended timestamps,
    /// Type 0/1/2/3 headers, and interleaved chunk streams.
    private func receiveRTMPChunk(firstByteTimeout: Duration? = .seconds(5)) async throws -> (Data, Int) {
        var totalBytesRead = 0
        let inMessageTimeout: Duration = firstByteTimeout ?? .seconds(5)
        var isFirstChunk = true

        while true {
            let basicTimeout = isFirstChunk ? firstByteTimeout : inMessageTimeout
            isFirstChunk = false

            guard let basicHeaderData = try await receiveDataExact(length: 1, timeout: basicTimeout),
                  basicHeaderData.count == 1 else {
                throw RTMPError.connectionFailed("Failed to receive chunk basic header")
            }
            totalBytesRead += 1
            let firstByte = basicHeaderData[0]
            let format = (firstByte >> 6) & 0x03
            var chunkStreamId = UInt32(firstByte & 0x3F)

            // Handle extended basic header for csid 0 and 1 (RTMP spec section 5.3.1.1)
            if chunkStreamId == 0 {
                guard let extendedByte = try await receiveDataExact(length: 1, timeout: inMessageTimeout),
                      extendedByte.count == 1 else {
                    throw RTMPError.connectionFailed("Failed to receive extended basic header (csid=0)")
                }
                chunkStreamId = UInt32(extendedByte[0]) + 64
                totalBytesRead += 1
            } else if chunkStreamId == 1 {
                guard let extendedBytes = try await receiveDataExact(length: 2, timeout: inMessageTimeout),
                      extendedBytes.count == 2 else {
                    throw RTMPError.connectionFailed("Failed to receive extended basic header (csid=1)")
                }
                chunkStreamId = (UInt32(extendedBytes[1]) << 8) + UInt32(extendedBytes[0]) + 64
                totalBytesRead += 2
            }

            // Read message header based on format type
            let headerSize: Int
            switch format {
            case 0: headerSize = 11
            case 1: headerSize = 7
            case 2: headerSize = 3
            default: headerSize = 0
            }

            var messageHeader = Data()
            if headerSize > 0 {
                guard let header = try await receiveDataExact(length: headerSize, timeout: inMessageTimeout),
                      header.count == headerSize else {
                    throw RTMPError.connectionFailed("Failed to receive message header")
                }
                messageHeader = header
                totalBytesRead += headerSize
            }

            let csState: ChunkStreamState
            if let existing = chunkStreamStates[chunkStreamId] {
                csState = existing
            } else {
                let created = ChunkStreamState()
                chunkStreamStates[chunkStreamId] = created
                csState = created
            }
            var rawTimestampField: UInt32 = 0

            switch format {
            case 0:
                rawTimestampField = UInt32(messageHeader[0]) << 16 | UInt32(messageHeader[1]) << 8 | UInt32(messageHeader[2])
                csState.messageLength = UInt32(messageHeader[3]) << 16 | UInt32(messageHeader[4]) << 8 | UInt32(messageHeader[5])
                csState.messageTypeId = messageHeader[6]
                csState.timestampDelta = 0
                if rawTimestampField != 0xFF_FFFF {
                    csState.timestamp = rawTimestampField
                    csState.hasExtendedTimestamp = false
                } else {
                    csState.hasExtendedTimestamp = true
                }
                csState.payloadBuffer = Data()
                csState.remainingBytes = csState.messageLength

            case 1:
                rawTimestampField = UInt32(messageHeader[0]) << 16 | UInt32(messageHeader[1]) << 8 | UInt32(messageHeader[2])
                csState.messageLength = UInt32(messageHeader[3]) << 16 | UInt32(messageHeader[4]) << 8 | UInt32(messageHeader[5])
                csState.messageTypeId = messageHeader[6]
                if rawTimestampField != 0xFF_FFFF {
                    csState.timestampDelta = rawTimestampField
                    csState.timestamp &+= rawTimestampField
                    csState.hasExtendedTimestamp = false
                } else {
                    csState.hasExtendedTimestamp = true
                }
                csState.payloadBuffer = Data()
                csState.remainingBytes = csState.messageLength

            case 2:
                rawTimestampField = UInt32(messageHeader[0]) << 16 | UInt32(messageHeader[1]) << 8 | UInt32(messageHeader[2])
                if rawTimestampField != 0xFF_FFFF {
                    csState.timestampDelta = rawTimestampField
                    csState.timestamp &+= rawTimestampField
                    csState.hasExtendedTimestamp = false
                } else {
                    csState.hasExtendedTimestamp = true
                }
                csState.payloadBuffer = Data()
                csState.remainingBytes = csState.messageLength

            default:  // Type 3
                if csState.remainingBytes == 0 {
                    // Starting a new message reusing previous chunk's length, type, and timestamp delta
                    if !csState.hasExtendedTimestamp {
                        csState.timestamp &+= csState.timestampDelta
                    }
                    csState.payloadBuffer = Data()
                    csState.remainingBytes = csState.messageLength
                }
            }

            // Read 4-byte extended timestamp when indicated
            let needsExtendedTimestamp = (format != 3 && rawTimestampField == 0xFF_FFFF) ||
                                         (format == 3 && csState.hasExtendedTimestamp)
            if needsExtendedTimestamp {
                guard let extTs = try await receiveDataExact(length: 4, timeout: inMessageTimeout),
                      extTs.count == 4 else {
                    throw RTMPError.connectionFailed("Failed to receive extended timestamp")
                }
                totalBytesRead += 4
                let extendedTimestamp = UInt32(extTs[0]) << 24 | UInt32(extTs[1]) << 16 |
                                        UInt32(extTs[2]) << 8 | UInt32(extTs[3])
                if format == 0 {
                    csState.timestamp = extendedTimestamp
                } else if format == 1 || format == 2 {
                    csState.timestampDelta = extendedTimestamp
                    csState.timestamp &+= extendedTimestamp
                } else if csState.payloadBuffer.isEmpty {
                    // Type 3 starting a new message with extended timestamp
                    csState.timestampDelta = extendedTimestamp
                    csState.timestamp &+= extendedTimestamp
                }
            }

            // Guard against excessive message sizes (> 1 MB)
            guard csState.messageLength <= 1_000_000 else {
                throw RTMPError.connectionFailed("Message too large: \(csState.messageLength) bytes")
            }

            // Read one chunk's worth of payload for this chunk stream
            let chunkSize = min(Int(csState.remainingBytes), max(1, receiveChunkSize))
            if chunkSize > 0 {
                guard let chunk = try await receiveDataExact(length: chunkSize, timeout: inMessageTimeout),
                      chunk.count == chunkSize else {
                    throw RTMPError.connectionFailed("Failed to receive chunk payload")
                }
                csState.payloadBuffer.append(chunk)
                csState.remainingBytes -= UInt32(chunkSize)
                totalBytesRead += chunkSize
            }

            if csState.remainingBytes == 0 {
                let completedPayload = csState.payloadBuffer
                csState.payloadBuffer = Data()
                lastReceivedMessageType = csState.messageTypeId
                return (completedPayload, totalBytesRead)
            }
        }
    }

    /// Receive exact amount of data, enforcing an actual deadline even when the peer sends 0 bytes.
    private func receiveDataExact(length: Int, timeout: Duration? = .seconds(5)) async throws -> Data? {
        guard length > 0 else { return Data() }

        var accumulated = Data()
        accumulated.reserveCapacity(length)
        var remaining = length
        let deadline = timeout.map { ContinuousClock.now.advanced(by: $0) }

        while remaining > 0 {
            let stepTimeout: Duration?
            if let deadline {
                let remainingTime = ContinuousClock.now.duration(to: deadline)
                if remainingTime <= .zero {
                    connection?.cancel()
                    throw RTMPError.connectionFailed("Timeout reading \(length) bytes (got \(accumulated.count) bytes)")
                }
                stepTimeout = remainingTime
            } else {
                stepTimeout = nil
            }

            guard let chunk = try await receiveData(length: remaining, timeout: stepTimeout) else {
                if accumulated.isEmpty {
                    return nil
                }
                throw RTMPError.connectionFailed("Connection closed mid-read (got \(accumulated.count)/\(length) bytes)")
            }

            accumulated.append(chunk)
            remaining -= chunk.count
        }

        return accumulated
    }

    /// Parse the createStream response to extract stream ID
    /// Format: "_result", transaction ID (4.0), info object, stream ID
    private func parseCreateStreamResponse(_ data: Data) throws -> UInt32 {
        var parser = AMF0Parser(data: data)

        let command = try parser.readValue()
        guard let commandName = command.stringValue, commandName == "_result" else {
            throw RTMPError.publishFailed("Expected '_result', got: \(command)")
        }

        let txnIdValue = try parser.readValue()
        guard let txnId = txnIdValue.numberValue, txnId == 4.0 else {
            throw RTMPError.publishFailed("Expected transaction ID 4.0, got: \(txnIdValue)")
        }

        // Skip command object (null or object with properties)
        try parser.skipValue()

        // Read stream ID (validate finite bounds before converting to UInt32)
        let streamIdValue = try parser.readValue()
        guard let streamIdNum = streamIdValue.numberValue,
              streamIdNum.isFinite,
              streamIdNum >= 0,
              streamIdNum <= Double(UInt32.max) else {
            throw RTMPError.publishFailed("Invalid stream ID number: \(streamIdValue)")
        }

        let parsedStreamId = UInt32(streamIdNum)
        print("✅ Parsed stream ID: \(parsedStreamId) (transaction ID: \(txnId))")
        return parsedStreamId
    }

    private func receiveData(length: Int, timeout: Duration?) async throws -> Data? {
        guard let connection = connection else {
            throw RTMPError.notConnected
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                let settled = OSAllocatedUnfairLock(initialState: false)
                let timeoutTask: Task<Void, Never>?

                if let timeout {
                    timeoutTask = Task {
                        do {
                            try await Task.sleep(for: timeout)
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        let shouldFail = settled.withLock { already -> Bool in
                            if already { return false }
                            already = true
                            return true
                        }
                        if shouldFail {
                            connection.cancel()
                            continuation.resume(throwing: RTMPError.connectionFailed("Receive timed out"))
                        }
                    }
                } else {
                    timeoutTask = nil
                }

                connection.receive(minimumIncompleteLength: 1, maximumLength: length) { data, _, isComplete, error in
                    let shouldResume = settled.withLock { already -> Bool in
                        if already { return false }
                        already = true
                        return true
                    }
                    timeoutTask?.cancel()
                    guard shouldResume else { return }

                    // Process non-empty data BEFORE checking isComplete so final TCP bytes are never dropped
                    if let data = data, !data.isEmpty {
                        continuation.resume(returning: data)
                        return
                    }

                    if let error = error {
                        print("❌ Receive error: \(error.localizedDescription)")
                        continuation.resume(throwing: RTMPError.connectionFailed(error.localizedDescription))
                        return
                    }

                    if isComplete {
                        print("❌ Connection closed by server (isComplete=true, no data)")
                        continuation.resume(throwing: RTMPError.connectionFailed("Connection closed"))
                        return
                    }

                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func calculateBitrate() -> Double {
        guard let startTime = startTime else { return 0 }
        let duration = Date().timeIntervalSince(startTime)
        guard duration > 0 else { return 0 }
        return Double(bytesSent * 8) / duration  // bits per second
    }
}
