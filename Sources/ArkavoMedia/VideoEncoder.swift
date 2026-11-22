import AVFoundation
import CoreVideo
import Synchronization
import VideoToolbox

/// Hardware-accelerated H.264 video encoder for streaming
/// Uses VTCompressionSession for efficient encoding
public final class VideoEncoder: @unchecked Sendable {
    // MARK: - Types

    public enum EncoderError: Error {
        case sessionCreationFailed(OSStatus)
        case encodingFailed(OSStatus)
        case invalidInput
    }

    public enum StreamQuality: Sendable {
        case high          // 1920x1080@30fps, 4500kbps
        case balanced      // 1920x1080@30fps, 3500kbps (default)
        case performance   // 1280x720@30fps, 2500kbps
        case auto          // Auto-detect based on CPU cores

        var config: (width: Int, height: Int, fps: Int32, bitrate: Int, maxBitrate: Int) {
            switch self {
            case .high:
                return (1920, 1080, 30, 4_500_000, 5_000_000)
            case .balanced:
                return (1920, 1080, 30, 3_500_000, 4_000_000)
            case .performance:
                return (1280, 720, 30, 2_500_000, 3_000_000)
            case .auto:
                return StreamQuality.detectOptimalQuality()
            }
        }

        private static func detectOptimalQuality() -> (width: Int, height: Int, fps: Int32, bitrate: Int, maxBitrate: Int) {
            let cpuCount = ProcessInfo.processInfo.processorCount

            // High-end: 8+ cores
            if cpuCount >= 8 {
                print("🎥 Auto-detected HIGH quality (CPU cores: \(cpuCount))")
                return StreamQuality.high.config
            }
            // Mid-range: 4-7 cores
            else if cpuCount >= 4 {
                print("🎥 Auto-detected BALANCED quality (CPU cores: \(cpuCount))")
                return StreamQuality.balanced.config
            }
            // Low-end: <4 cores
            else {
                print("🎥 Auto-detected PERFORMANCE quality (CPU cores: \(cpuCount))")
                return StreamQuality.performance.config
            }
        }
    }

    /// Retained by the active `VTCompressionSession` as its `refcon` and released
    /// only after `VTCompressionSessionInvalidate` completes, eliminating any
    /// use-after-free hazard if `VideoEncoder` is stopped or deallocated while a
    /// VideoToolbox callback is in flight.
    private final class CallbackContext: Sendable {
        private struct State {
            var isActive: Bool
            var onFrame: (@Sendable (EncodedVideoFrame) -> Void)?
        }

        private let state: Mutex<State>

        init(onFrame: (@Sendable (EncodedVideoFrame) -> Void)?) {
            self.state = Mutex(State(isActive: true, onFrame: onFrame))
        }

        var isActive: Bool {
            state.withLock { $0.isActive }
        }

        @discardableResult
        func setOnFrame(_ handler: (@Sendable (EncodedVideoFrame) -> Void)?) -> (@Sendable (EncodedVideoFrame) -> Void)? {
            state.withLock { state in
                let previous = state.onFrame
                state.onFrame = handler
                return previous
            }
        }

        func deactivate() {
            let previous = state.withLock { state -> (@Sendable (EncodedVideoFrame) -> Void)? in
                state.isActive = false
                let old = state.onFrame
                state.onFrame = nil
                return old
            }
            _ = previous
        }

        func activeHandler() -> (@Sendable (EncodedVideoFrame) -> Void)? {
            state.withLock { $0.isActive ? $0.onFrame : nil }
        }
    }

    private struct SessionState {
        var compressionSession: VTCompressionSession?
        var callbackContextPtr: UnsafeMutableRawPointer?
        var activeContext: CallbackContext?
        var onFrame: (@Sendable (EncodedVideoFrame) -> Void)?
        var isEncoding: Bool = false
        var sentSequenceHeader: Bool = false
    }

    // MARK: - Properties

    private let sessionLock = NSLock()
    private var sessionState = SessionState()

    private let width: Int
    private let height: Int
    private let fps: Int32
    private let bitrate: Int
    private let maxBitrate: Int

    /// Callback invoked when an H.264 frame is ready
    public var onFrame: (@Sendable (EncodedVideoFrame) -> Void)? {
        get {
            sessionLock.lock()
            defer { sessionLock.unlock() }
            return sessionState.onFrame
        }
        set {
            sessionLock.lock()
            let previousHandler = sessionState.onFrame
            sessionState.onFrame = newValue
            let previousContextHandler = sessionState.activeContext?.setOnFrame(newValue)
            sessionLock.unlock()
            _ = previousHandler
            _ = previousContextHandler
        }
    }

    /// Internal test inspection of active session/callback context state.
    var isRunning: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionState.compressionSession != nil && sessionState.isEncoding
    }

    /// Internal test inspection of whether the active session's callback context is active.
    var hasActiveCallbackContext: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionState.activeContext?.isActive ?? false
    }

    // MARK: - Initialization

    public init(quality: StreamQuality = .auto) {
        let config = quality.config
        self.width = config.width
        self.height = config.height
        self.fps = config.fps
        self.bitrate = config.bitrate
        self.maxBitrate = config.maxBitrate

        print("🎥 VideoEncoder initialized: \(width)x\(height)@\(fps)fps, bitrate=\(bitrate/1000)kbps")
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Start encoding
    public func start() throws {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        guard sessionState.compressionSession == nil else { return }

        let context = CallbackContext(onFrame: sessionState.onFrame)
        let retainedPtr = Unmanaged.passRetained(context).toOpaque()

        let enableHardwareAcceleration: CFBoolean = kCFBooleanTrue
        let encoderSpecification: CFDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: enableHardwareAcceleration
        ] as CFDictionary

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.compressionOutputCallback,
            refcon: retainedPtr,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            context.deactivate()
            Unmanaged<CallbackContext>.fromOpaque(retainedPtr).release()
            throw EncoderError.sessionCreationFailed(status)
        }

        // Configure session for RTMP streaming
        configureSession(session)

        // Prepare session
        VTCompressionSessionPrepareToEncodeFrames(session)

        sessionState.compressionSession = session
        sessionState.callbackContextPtr = retainedPtr
        sessionState.activeContext = context
        sessionState.isEncoding = true
        sessionState.sentSequenceHeader = false

        print("✅ VTCompressionSession created: \(width)x\(height)@\(fps)fps, bitrate=\(bitrate/1000)kbps (max=\(maxBitrate/1000)kbps), profile=High")
    }

    /// Stop encoding
    public func stop() {
        let tornDown: (VTCompressionSession, UnsafeMutableRawPointer?, CallbackContext?)? = {
            sessionLock.lock()
            defer { sessionLock.unlock() }
            guard let session = sessionState.compressionSession else { return nil }
            let ptr = sessionState.callbackContextPtr
            let context = sessionState.activeContext
            sessionState.compressionSession = nil
            sessionState.callbackContextPtr = nil
            sessionState.activeContext = nil
            sessionState.isEncoding = false
            sessionState.sentSequenceHeader = false
            return (session, ptr, context)
        }()

        guard let (session, contextPtr, activeContext) = tornDown else { return }

        activeContext?.deactivate()

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)

        // VideoToolbox guarantees no further output callbacks after Invalidate returns.
        if let contextPtr {
            Unmanaged<CallbackContext>.fromOpaque(contextPtr).release()
        }

        print("🛑 VideoEncoder stopped")
    }

    /// Encode a video frame
    /// - Parameters:
    ///   - pixelBuffer: Video frame to encode
    ///   - timestamp: Presentation timestamp
    public func encode(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) throws {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        guard let session = sessionState.compressionSession, sessionState.isEncoding else {
            throw EncoderError.invalidInput
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        guard status == noErr else {
            throw EncoderError.encodingFailed(status)
        }
    }

    // MARK: - Private Methods

    private func configureSession(_ session: VTCompressionSession) {
        // Real-time encoding for low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Use High profile for better compression
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)

        // Bitrate configuration - use CBR for consistent stream
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)

        // CRITICAL: Set DataRateLimits to cap keyframe size and prevent spikes
        let bytesPerSecond = maxBitrate / 8
        let dataRateLimits: [CFNumber] = [bytesPerSecond as CFNumber, 1 as CFNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)

        // Frame rate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)

        // Keyframe interval: every 2 seconds
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int32(fps * 2) as CFNumber)

        // Disable B-frames for RTMP compatibility
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Use constant bitrate mode for consistent streaming
        // AverageBitRate + DataRateLimits together enforce CBR-like behavior.
        // Do NOT set Quality — it overrides bitrate targets and reduces output.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ConstantBitRate, value: bitrate as CFNumber)

        print("   DataRateLimits: \(bytesPerSecond/1000)KB/s in 1-second windows, CBR target: \(bitrate/1000)kbps")
    }

    private static let compressionOutputCallback: VTCompressionOutputCallback = { (
        outputCallbackRefCon: UnsafeMutableRawPointer?,
        _: UnsafeMutableRawPointer?,
        status: OSStatus,
        _: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) in
        guard status == noErr, let sampleBuffer = sampleBuffer else {
            print("❌ Compression failed with status: \(status)")
            return
        }

        guard let refcon = outputCallbackRefCon else { return }
        let context = Unmanaged<CallbackContext>.fromOpaque(refcon).takeUnretainedValue()
        guard let handler = context.activeHandler() else { return }

        VideoEncoder.handleCompressedFrame(sampleBuffer, handler: handler)
    }

    private static func handleCompressedFrame(
        _ sampleBuffer: CMSampleBuffer,
        handler: @Sendable (EncodedVideoFrame) -> Void
    ) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            print("❌ No data buffer in compressed frame")
            return
        }

        // Extract H.264 data. The block buffer can be non-contiguous (VideoToolbox's CBR filler can
        // sit in its own memory block), so copy through CMBlockBufferCopyDataBytes rather than
        // reading totalLength bytes from the first block's pointer, which read past that block.
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else {
            print("❌ Empty compressed frame")
            return
        }
        var h264Data = Data(count: length)
        let status = h264Data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == kCMBlockBufferNoErr else {
            print("❌ Failed to copy compressed frame (\(status))")
            return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Determine if this is a keyframe
        // If kCMSampleAttachmentKey_NotSync is missing or false, it's a keyframe
        let notSync = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            .flatMap { ($0 as? [[CFString: Any]])?.first }
            .flatMap { $0[kCMSampleAttachmentKey_NotSync] as? Bool } ?? false
        let isKeyframe = !notSync

        let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)

        // Create encoded frame
        let frame = EncodedVideoFrame(
            data: h264Data,
            pts: timestamp,
            isKeyframe: isKeyframe,
            formatDescription: formatDesc
        )

        handler(frame)
    }
}
