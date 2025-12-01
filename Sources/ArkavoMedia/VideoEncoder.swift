import AVFoundation
import CoreVideo
import VideoToolbox

/// Hardware-accelerated H.264 video encoder for streaming
/// Uses VTCompressionSession for efficient encoding
public final class VideoEncoder: Sendable {
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

    // MARK: - Properties

    nonisolated(unsafe) private var compressionSession: VTCompressionSession?

    private let width: Int
    private let height: Int
    private let fps: Int32
    private let bitrate: Int
    private let maxBitrate: Int

    nonisolated(unsafe) private var isEncoding = false
    nonisolated(unsafe) private var sentSequenceHeader = false

    /// Callback invoked when an H.264 frame is ready
    nonisolated(unsafe) public var onFrame: (@Sendable (EncodedVideoFrame) -> Void)?

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

    // MARK: - Public Methods

    /// Start encoding
    public func start() throws {
        guard compressionSession == nil else { return }

        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw EncoderError.sessionCreationFailed(status)
        }

        // Configure session for RTMP streaming
        configureSession(session)

        // Prepare session
        VTCompressionSessionPrepareToEncodeFrames(session)

        compressionSession = session
        isEncoding = true
        sentSequenceHeader = false

        print("✅ VTCompressionSession created: \(width)x\(height)@\(fps)fps, bitrate=\(bitrate/1000)kbps (max=\(maxBitrate/1000)kbps), profile=High")
    }

    /// Stop encoding
    public func stop() {
        guard let session = compressionSession else { return }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)

        compressionSession = nil
        isEncoding = false
        sentSequenceHeader = false

        print("🛑 VideoEncoder stopped")
    }

    /// Encode a video frame
    /// - Parameters:
    ///   - pixelBuffer: Video frame to encode
    ///   - timestamp: Presentation timestamp
    public func encode(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) throws {
        guard let session = compressionSession else {
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

        // Set quality - balanced for real-time streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.5 as CFNumber)

        // Enable hardware acceleration
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, value: kCFBooleanTrue)

        print("   DataRateLimits: \(bytesPerSecond/1000)KB/s in 1-second windows")
    }

    private let compressionOutputCallback: VTCompressionOutputCallback = { (
        outputCallbackRefCon: UnsafeMutableRawPointer?,
        sourceFrameRefCon: UnsafeMutableRawPointer?,
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) in
        guard status == noErr, let sampleBuffer = sampleBuffer else {
            print("❌ Compression failed with status: \(status)")
            return
        }

        guard let encoder = outputCallbackRefCon else { return }
        let videoEncoder = Unmanaged<VideoEncoder>.fromOpaque(encoder).takeUnretainedValue()

        videoEncoder.handleCompressedFrame(sampleBuffer)
    }

    private func handleCompressedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            print("❌ No data buffer in compressed frame")
            return
        }

        // Extract H.264 data
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            print("❌ Failed to get data pointer")
            return
        }

        let h264Data = Data(bytes: data, count: length)
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

        onFrame?(frame)

        // Log frames for debugging
        if isKeyframe {
            print("🎥 Encoded keyframe: \(h264Data.count) bytes at \(timestamp.seconds)s")
        } else {
            // Log P-frames occasionally using static counter
            let count = Self.incrementFrameCount()
            if count % 30 == 0 {
                print("🎥 Encoded P-frame #\(count): \(h264Data.count) bytes at \(timestamp.seconds)s")
            }
        }
    }

    // Static counter for P-frame logging (thread-safe via lock)
    private static let frameCountLock = NSLock()
    private nonisolated(unsafe) static var _frameCount: Int = 0
    private static func incrementFrameCount() -> Int {
        frameCountLock.lock()
        defer { frameCountLock.unlock() }
        _frameCount += 1
        return _frameCount
    }
}
