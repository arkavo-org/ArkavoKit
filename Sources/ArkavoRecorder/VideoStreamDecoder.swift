import AVFoundation
import CoreMedia
import VideoToolbox

/// Hardware-accelerated H.264 video decoder for streaming
/// Uses VideoToolbox VTDecompressionSession for efficient decoding
public final class VideoStreamDecoder {
    // MARK: - Types

    /// Callback invoked when decoded frame is ready
    /// - Parameters:
    ///   - pixelBuffer: Decoded video frame
    ///   - timestamp: Presentation timestamp
    public typealias OutputHandler = (CVPixelBuffer, CMTime) -> Void

    // MARK: - Properties

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private let outputHandler: OutputHandler
    private let outputQueue = DispatchQueue(label: "com.arkavo.video-stream-decoder")

    private var isDecoding = false

    // MARK: - Initialization

    public init(outputHandler: @escaping OutputHandler) {
        self.outputHandler = outputHandler
    }

    deinit {
        invalidate()
    }

    // MARK: - Public Methods

    /// Decode H.264 NAL unit data
    /// - Parameters:
    ///   - data: H.264 NAL unit data (can include SPS/PPS or frame data)
    ///   - isKeyFrame: True if this is an I-frame
    ///   - timestamp: Presentation timestamp
    public func decode(_ data: Data, isKeyFrame: Bool, timestamp: CMTime) throws {
        // Create or update format description if needed (from SPS/PPS)
        if isKeyFrame {
            try updateFormatDescription(from: data)
        }

        guard let formatDescription = formatDescription else {
            throw DecoderError.noFormatDescription
        }

        // Create decompression session if needed
        if decompressionSession == nil {
            try setupDecompressionSession(formatDescription: formatDescription)
        }

        guard let session = decompressionSession else {
            throw DecoderError.sessionNotReady
        }

        // Create block buffer from NAL unit data
        var blockBuffer: CMBlockBuffer?
        let status = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }

            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: baseAddress),
                blockLength: data.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard status == noErr, let blockBuffer = blockBuffer else {
            throw DecoderError.blockBufferCreationFailed(status)
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )

        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            throw DecoderError.sampleBufferCreationFailed(sampleStatus)
        }

        // Mark as sync sample if keyframe
        if isKeyFrame {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [[CFString: Any]]
            if var attachments = attachments, !attachments.isEmpty {
                attachments[0][kCMSampleAttachmentKey_NotSync] = kCFBooleanFalse
            }
        }

        // Decode
        var infoFlags: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )

        guard decodeStatus == noErr else {
            throw DecoderError.decodingFailed(decodeStatus)
        }
    }

    /// Start decoding
    public func start() {
        isDecoding = true
    }

    /// Stop decoding and flush pending frames
    public func stop() async throws {
        guard isDecoding else { return }
        isDecoding = false

        guard let session = decompressionSession else { return }

        // Flush remaining frames
        let status = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr else {
            throw DecoderError.flushFailed(status)
        }
    }

    /// Invalidate the decoder
    public func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        isDecoding = false
    }

    // MARK: - Private Methods

    private func updateFormatDescription(from data: Data) throws {
        // Extract SPS and PPS from H.264 stream
        // This is a simplified version - full implementation would parse NAL units properly
        // For now, we'll try to create format description from the data

        // In a real implementation, you would parse NAL units to extract SPS/PPS
        // For this implementation, we'll assume the format description can be created
        // from the compressed data directly or we'll handle it when we receive the first frame

        // TODO: Implement proper SPS/PPS extraction and format description creation
        // For now, we'll create it lazily when we receive actual frame data
    }

    private func setupDecompressionSession(formatDescription: CMFormatDescription) throws {
        var session: VTDecompressionSession?

        // Decoder attributes
        let decoderAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue as Any,
            kCVPixelBufferOpenGLCompatibilityKey: kCFBooleanTrue as Any
        ]

        // Output callback
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        // Create decompression session
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: decoderAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw DecoderError.sessionCreationFailed(status)
        }

        // Configure session for real-time playback
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.decompressionSession = session
    }

    // MARK: - Decompression Callback

    private let decompressionOutputCallback: VTDecompressionOutputCallback = { (
        decompressionOutputRefCon: UnsafeMutableRawPointer?,
        _: UnsafeMutableRawPointer?,
        status: OSStatus,
        _: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        _: CMTime
    ) in
        guard status == noErr else {
            print("❌ [VideoStreamDecoder] Decompression error: \(status)")
            return
        }

        guard let imageBuffer = imageBuffer else {
            print("❌ [VideoStreamDecoder] No image buffer")
            return
        }

        guard let refCon = decompressionOutputRefCon else {
            print("❌ [VideoStreamDecoder] No refcon")
            return
        }

        let decoder = Unmanaged<VideoStreamDecoder>.fromOpaque(refCon).takeUnretainedValue()
        decoder.handleDecodedFrame(imageBuffer, timestamp: presentationTimeStamp)
    }

    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        outputQueue.async { [weak self] in
            self?.outputHandler(pixelBuffer, timestamp)
        }
    }

    // MARK: - Errors

    public enum DecoderError: Error {
        case noFormatDescription
        case sessionCreationFailed(OSStatus)
        case sessionNotReady
        case blockBufferCreationFailed(OSStatus)
        case sampleBufferCreationFailed(OSStatus)
        case decodingFailed(OSStatus)
        case flushFailed(OSStatus)
    }
}

// MARK: - H.264 NAL Unit Utilities

extension VideoStreamDecoder {
    /// Create format description from H.264 parameter sets (SPS/PPS)
    /// - Parameters:
    ///   - sps: Sequence Parameter Set NAL unit
    ///   - pps: Picture Parameter Set NAL unit
    /// - Returns: CMFormatDescription for H.264 video
    public static func createFormatDescription(sps: Data, pps: Data) throws -> CMFormatDescription {
        let parameterSets = [sps, pps]

        var formatDescription: CMFormatDescription?

        // Use withUnsafeBytes to get proper pointers
        try sps.withUnsafeBytes { spsBytes in
            try pps.withUnsafeBytes { ppsBytes in
                guard let spsPointer = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPointer = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw DecoderError.noFormatDescription
                }

                let pointers: [UnsafePointer<UInt8>] = [spsPointer, ppsPointer]
                let sizes: [Int] = [sps.count, pps.count]

                let status = pointers.withUnsafeBufferPointer { pointersBuffer in
                    sizes.withUnsafeBufferPointer { sizesBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointersBuffer.baseAddress!,
                            parameterSetSizes: sizesBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }

                guard status == noErr else {
                    throw DecoderError.sessionCreationFailed(status)
                }
            }
        }

        guard let formatDescription = formatDescription else {
            throw DecoderError.sessionCreationFailed(-1)
        }

        return formatDescription
    }
}
