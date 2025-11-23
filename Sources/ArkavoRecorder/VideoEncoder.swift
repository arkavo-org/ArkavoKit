@preconcurrency import AVFoundation
import CoreVideo
import VideoToolbox
import AudioToolbox
import ArkavoStreaming
import ArkavoMedia

/// Encodes video and audio to MOV files using AVAssetWriter
/// Supports optional simultaneous streaming via RTMP using VTCompressionSession
public final class VideoEncoder: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private var assetWriter: AVAssetWriter?
    nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
    nonisolated(unsafe) private var audioInputs: [String: AVAssetWriterInput] = [:]  // sourceID -> audio input
    nonisolated(unsafe) private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // ArkavoMedia encoders for streaming
    nonisolated(unsafe) private var streamVideoEncoder: ArkavoMedia.VideoEncoder?
    nonisolated(unsafe) private var streamAudioEncoder: ArkavoMedia.AudioEncoder?

    nonisolated(unsafe) private var outputURL: URL?
    nonisolated(unsafe) private var startTime: CMTime?
    nonisolated(unsafe) private var lastVideoTimestamp: CMTime = .zero
    nonisolated(unsafe) private var isPaused: Bool = false
    nonisolated(unsafe) private var pauseStartTime: CMTime?
    nonisolated(unsafe) private var totalPausedDuration: CMTime = .zero

    nonisolated(unsafe) public private(set) var isRecording: Bool = false

    // Streaming support
    nonisolated(unsafe) private var rtmpPublisher: RTMPPublisher?
    nonisolated(unsafe) private var isStreaming: Bool = false
    nonisolated(unsafe) private var videoFormatDescription: CMFormatDescription?
    nonisolated(unsafe) private var audioFormatDescription: CMFormatDescription?
    nonisolated(unsafe) private var sentVideoSequenceHeader: Bool = false
    nonisolated(unsafe) private var sentAudioSequenceHeader: Bool = false
    nonisolated(unsafe) private var streamStartTime: CMTime?  // Stream start time for relative timestamps
    nonisolated(unsafe) private var lastStreamVideoTimestamp: CMTime = .zero  // Last video timestamp sent to stream
    nonisolated(unsafe) private var lastStreamAudioTimestamp: CMTime = .zero  // Last audio timestamp sent to stream

    // Encoding settings - adaptive based on system capabilities
    private let videoWidth: Int
    private let videoHeight: Int
    private let frameRate: Int32
    private let videoBitrate: Int
    private let videoBitrateMax: Int  // Maximum bitrate for CBR limiting
    private let audioBitrate: Int

    // Quality presets for adaptive streaming
    public enum StreamQuality: Sendable {
        case high          // 1080p@30fps, 4500kbps - Good CPU, good network
        case balanced      // 1080p@30fps, 3500kbps - Default, best compatibility
        case performance   // 720p@30fps, 2500kbps - Lower CPU/network
        case auto          // Automatically select based on system

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

            // High-end: 8+ cores (M1/M2/M3 Pro/Max, i9, etc.)
            if cpuCount >= 8 {
                print("🎥 Auto-detected HIGH quality (CPU cores: \(cpuCount))")
                return StreamQuality.high.config
            }
            // Mid-range: 4-7 cores (M1/M2 base, i5/i7)
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

    // MARK: - Public Methods

    public init(quality: StreamQuality = .auto) {
        // Configure encoding parameters based on quality preset
        let config = quality.config
        self.videoWidth = config.width
        self.videoHeight = config.height
        self.frameRate = config.fps
        self.videoBitrate = config.bitrate
        self.videoBitrateMax = config.maxBitrate
        self.audioBitrate = 128_000  // 128 kbps AAC - standard for all qualities

        print("🎥 VideoEncoder initialized: \(videoWidth)x\(videoHeight)@\(frameRate)fps, bitrate=\(videoBitrate/1000)kbps (max=\(videoBitrateMax/1000)kbps)")
    }

    /// Starts recording to the specified output file
    /// - Parameters:
    ///   - url: Output file URL
    ///   - title: Recording title for metadata
    ///   - audioSourceIDs: Optional array of audio source IDs to pre-create tracks for
    public func startRecording(to url: URL, title: String, audioSourceIDs: [String] = []) async throws {
        guard !isRecording else { return }

        outputURL = url

        // Remove existing file if present
        try? FileManager.default.removeItem(at: url)

        // Create asset writer
        assetWriter = try AVAssetWriter(url: url, fileType: .mov)

        guard let assetWriter = assetWriter else {
            throw RecorderError.encodingFailed
        }

        // Setup video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                // Use High profile for better compression/quality
                // High profile is widely supported and provides smaller file sizes
                AVVideoProfileLevelKey: AVVideoProfileLevelH264High41,
                // Disable frame reordering for RTMP compatibility
                AVVideoAllowFrameReorderingKey: false,
                // Set max keyframe interval (2 seconds)
                AVVideoMaxKeyFrameIntervalKey: Int(frameRate * 2)
            ],
            // Add color space metadata for proper color reproduction
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true

        // Setup pixel buffer adaptor
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput!,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        if let videoInput = videoInput {
            assetWriter.add(videoInput)
        }

        // Pre-create audio inputs for known sources
        // This must be done BEFORE startWriting() because you cannot add inputs after the session starts
        audioInputs = [:]
        print("🎵 VideoEncoder: Pre-creating audio inputs for \(audioSourceIDs.count) source(s): \(audioSourceIDs)")
        for sourceID in audioSourceIDs {
            print("🎵 VideoEncoder: Creating audio input for: \(sourceID)")
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioBitrate,  // 128 kbps
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,  // Force AAC-LC profile
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant  // CBR
            ]

            let newInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            newInput.expectsMediaDataInRealTime = true

            // Add metadata to identify the source
            let sourceMetadata = AVMutableMetadataItem()
            sourceMetadata.key = "source" as NSString
            sourceMetadata.value = sourceID as NSString
            newInput.metadata = [sourceMetadata]

            assetWriter.add(newInput)
            audioInputs[sourceID] = newInput
            print("✅ VideoEncoder: Pre-created AAC audio track for source: \(sourceID)")
        }
        print("🎵 VideoEncoder: Total audio inputs created: \(audioInputs.count)")

        // Add metadata
        assetWriter.metadata = createMetadata(title: title)

        // Start writing
        guard assetWriter.startWriting() else {
            print("❌ VideoEncoder: Failed to start asset writer")
            if let error = assetWriter.error {
                print("   Error: \(error.localizedDescription)")
            }
            throw RecorderError.encodingFailed
        }

        isRecording = true
        print("✅ VideoEncoder: Recording started. isRecording = \(isRecording)")
        startTime = nil
        lastVideoTimestamp = .zero
        isPaused = false
        pauseStartTime = nil
        totalPausedDuration = .zero
    }

    /// Finishes recording and returns the output URL
    public func finishRecording() async throws -> URL {
        guard isRecording else {
            print("❌ finishRecording: Not currently recording")
            throw RecorderError.encodingFailed
        }

        guard let assetWriter = assetWriter else {
            print("❌ finishRecording: Asset writer is nil")
            throw RecorderError.encodingFailed
        }

        guard let outputURL = outputURL else {
            print("❌ finishRecording: Output URL is nil")
            throw RecorderError.encodingFailed
        }

        isRecording = false

        // Check if a session was actually started (at least one frame was written)
        let sessionStarted = startTime != nil
        print("📊 Session started: \(sessionStarted), Asset writer status: \(assetWriter.status.rawValue)")

        // Only finish if a session was started and asset writer is in writing state
        if sessionStarted && assetWriter.status == .writing {
            print("📝 Marking inputs as finished...")

            // Mark inputs as finished if they exist and are ready
            if let videoInput = videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.markAsFinished()
                print("  ✓ Video input marked as finished")
            } else {
                print("  ⚠️ Video input not ready or nil")
            }

            // Mark all audio inputs as finished
            for (sourceID, audioInput) in audioInputs {
                if audioInput.isReadyForMoreMediaData {
                    audioInput.markAsFinished()
                    print("  ✓ Audio input [\(sourceID)] marked as finished")
                } else {
                    print("  ⚠️ Audio input [\(sourceID)] not ready")
                }
            }

            // Finish writing
            print("⏳ Finishing asset writer...")
            await assetWriter.finishWriting()
            print("✅ Asset writer finished with status: \(assetWriter.status.rawValue)")
        } else if !sessionStarted {
            print("⚠️ No frames were written (session never started), cancelling asset writer")
            assetWriter.cancelWriting()
        } else {
            print("⚠️ Asset writer not in writing state (status: \(assetWriter.status.rawValue)), cannot finish")
        }

        if assetWriter.status == .failed {
            let errorMessage = assetWriter.error?.localizedDescription ?? "Unknown error"
            let underlyingError = (assetWriter.error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError
            print("❌ Asset writer failed: \(errorMessage)")
            if let underlyingError = underlyingError {
                print("   Underlying error: Domain=\(underlyingError.domain) Code=\(underlyingError.code)")
            }
            throw assetWriter.error ?? RecorderError.encodingFailed
        }

        // Clean up
        self.assetWriter = nil
        self.videoInput = nil
        self.audioInputs = [:]
        self.pixelBufferAdaptor = nil

        print("✅ Recording finished successfully at: \(outputURL.path)")
        return outputURL
    }

    /// Pauses recording
    public func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pauseStartTime = lastVideoTimestamp
    }

    /// Resumes recording
    public func resume() {
        guard isRecording, isPaused, let pauseStart = pauseStartTime else { return }
        isPaused = false
        totalPausedDuration = CMTimeAdd(totalPausedDuration, CMTimeSubtract(lastVideoTimestamp, pauseStart))
        pauseStartTime = nil
    }

    /// Current recording duration
    public var duration: TimeInterval {
        guard let startTime = startTime else { return 0 }
        let adjustedDuration = CMTimeSubtract(lastVideoTimestamp, startTime)
        let finalDuration = CMTimeSubtract(adjustedDuration, totalPausedDuration)
        return CMTimeGetSeconds(finalDuration)
    }

    // MARK: - Frame Encoding

    /// Encodes a video frame
    public nonisolated func encodeVideoFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) async {
        guard isRecording, !isPaused else { return }
        guard let videoInput = videoInput, let adaptor = pixelBufferAdaptor else { return }
        guard let assetWriter = assetWriter else { return }

        // Validate timestamp
        guard timestamp.isValid, timestamp.seconds >= 0 else {
            print("⚠️ Invalid timestamp: \(timestamp)")
            return
        }

        // Initialize start time on first frame
        if startTime == nil {
            startTime = timestamp
            assetWriter.startSession(atSourceTime: timestamp)
            lastVideoTimestamp = timestamp
        }

        // Wait if input is not ready
        if !videoInput.isReadyForMoreMediaData {
            return
        }

        // Check if asset writer is still healthy before appending
        guard assetWriter.status == .writing else {
            if assetWriter.status == .failed {
                let errorMessage = assetWriter.error?.localizedDescription ?? "Unknown error"
                let underlyingError = (assetWriter.error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError
                print("❌ Asset writer failed during video encoding: \(errorMessage)")
                if let underlyingError = underlyingError {
                    print("   Underlying error: Domain=\(underlyingError.domain) Code=\(underlyingError.code)")
                }
            }
            return
        }

        // Adjust timestamp for pauses
        var adjustedTimestamp = timestamp
        if !totalPausedDuration.seconds.isZero {
            adjustedTimestamp = CMTimeSubtract(timestamp, totalPausedDuration)
        }

        // Ensure timestamps are monotonically increasing
        if CMTimeCompare(adjustedTimestamp, lastVideoTimestamp) <= 0 {
            // Timestamp is not increasing, skip this frame
            print("⚠️ Dropping frame with non-increasing timestamp: \(adjustedTimestamp.seconds) <= \(lastVideoTimestamp.seconds)")
            return
        }

        // Append pixel buffer to file
        if !adaptor.append(pixelBuffer, withPresentationTime: adjustedTimestamp) {
            print("❌ Failed to append video frame at timestamp \(adjustedTimestamp.seconds)")
            if assetWriter.status == .failed {
                let errorMessage = assetWriter.error?.localizedDescription ?? "Unknown error"
                let underlyingError = (assetWriter.error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError
                print("   Asset writer error: \(errorMessage)")
                if let underlyingError = underlyingError {
                    print("   Underlying error: Domain=\(underlyingError.domain) Code=\(underlyingError.code)")
                }
            }
            return
        }
        lastVideoTimestamp = adjustedTimestamp

        // Also stream if streaming is active
        if isStreaming, let encoder = streamVideoEncoder {
            do {
                try encoder.encode(pixelBuffer, timestamp: adjustedTimestamp)
            } catch {
                print("❌ Stream video encoder failed: \(error)")
            }
        }
    }

    /// Encodes an audio sample from a specific source
    /// - Parameters:
    ///   - sampleBuffer: Audio sample buffer (must be 48kHz PCM stereo)
    ///   - sourceID: Unique identifier for the audio source (e.g., "microphone", "screen", "remote-camera-123")
    public nonisolated func encodeAudioSample(_ sampleBuffer: CMSampleBuffer, sourceID: String) async {
        // Allow audio processing if either recording OR streaming
        guard (isRecording || isStreaming) && !isPaused else { return }

        guard CMSampleBufferIsValid(sampleBuffer) else {
            return
        }

        // Handle file recording if active
        if isRecording {
            guard startTime != nil else {
                // Wait until video session has started to keep A/V in sync
                return
            }

            guard let writer = assetWriter, writer.status == .writing else {
                return
            }

            // Get audio input for this source (must have been pre-created during startRecording)
            guard let audioInput = audioInputs[sourceID] else {
                print("⚠️ No audio input exists for source: \(sourceID). Audio inputs must be pre-created before recording starts.")
                return
            }

            // Wait if input is not ready
            if !audioInput.isReadyForMoreMediaData {
                return
            }

            // Adjust timestamp for pauses
            var adjustedBuffer = sampleBuffer
            if !totalPausedDuration.seconds.isZero {
                // Create adjusted sample buffer with new timing
                // This is simplified - full implementation would need proper timing adjustment
                adjustedBuffer = sampleBuffer
            }

            // Append audio sample to file
            // AVAssetWriterInput will automatically encode PCM to AAC
            if !audioInput.append(adjustedBuffer) {
                print("⚠️ Audio input [\(sourceID)] rejected sample buffer; dropping frame")
                return
            }
        }

        // Stream the first audio track for RTMP (typically microphone)
        if isStreaming, let encoder = streamAudioEncoder, sourceID == "microphone" {
            // Feed PCM audio to encoder for AAC conversion
            encoder.feed(sampleBuffer)
        }
    }

    /// Legacy method for backward compatibility - routes to "microphone" source
    public nonisolated func encodeAudioSample(_ sampleBuffer: CMSampleBuffer) async {
        await encodeAudioSample(sampleBuffer, sourceID: "microphone")
    }

    // MARK: - Private Methods

    private func createMetadata(title: String) -> [AVMetadataItem] {
        var metadata: [AVMetadataItem] = []

        // Title
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        metadata.append(titleItem)

        // Creator
        let creatorItem = AVMutableMetadataItem()
        creatorItem.identifier = .commonIdentifierCreator
        creatorItem.value = "Arkavo Creator" as NSString
        metadata.append(creatorItem)

        // Software
        let softwareItem = AVMutableMetadataItem()
        softwareItem.identifier = .commonIdentifierSoftware
        softwareItem.value = "Arkavo Creator v1.0" as NSString
        metadata.append(softwareItem)

        // Creation date
        let dateItem = AVMutableMetadataItem()
        dateItem.identifier = .commonIdentifierCreationDate
        dateItem.value = ISO8601DateFormatter().string(from: Date()) as NSString
        metadata.append(dateItem)

        return metadata
    }

    // MARK: - Streaming Methods

    /// Start streaming to RTMP destination(s) while recording
    public func startStreaming(to destination: RTMPPublisher.Destination, streamKey: String) async throws {
        guard !isStreaming else {
            print("⚠️ Already streaming")
            return
        }

        print("📡 Starting RTMP stream...")

        let publisher = RTMPPublisher()
        try await publisher.connect(to: destination, streamKey: streamKey)

        // Send stream metadata (@setDataFrame onMetaData) immediately after connect
        try await publisher.sendMetadata(
            width: videoWidth,
            height: videoHeight,
            framerate: Double(frameRate),
            videoBitrate: Double(videoBitrate) / 1000.0,  // Convert to kbps
            audioBitrate: 128.0  // 128 kbps
        )

        // Create video encoder
        let videoEncoder = ArkavoMedia.VideoEncoder(quality: .auto)
        try videoEncoder.start()

        // Create audio encoder
        let audioEncoder = try ArkavoMedia.AudioEncoder(bitrate: 128_000)

        // Wire up video encoder callback
        videoEncoder.onFrame = { [weak self, weak publisher] frame in
            Task { [weak self] in
                do {
                    // Send sequence header ONLY ONCE on first keyframe
                    if frame.isKeyframe, self?.sentVideoSequenceHeader == false, let formatDesc = frame.formatDescription {
                        try await publisher?.sendVideoSequenceHeader(formatDescription: formatDesc)
                        self?.sentVideoSequenceHeader = true
                        print("✅ Sent video sequence header (ONCE)")
                    }

                    // Send video frame
                    try await publisher?.send(video: frame)
                } catch {
                    print("❌ Failed to send video frame: \(error)")
                }
            }
        }

        // Wire up audio encoder callback
        audioEncoder.onFrame = { [weak self, weak publisher] frame in
            Task { [weak self] in
                do {
                    // Send sequence header ONLY ONCE on first frame
                    if self?.sentAudioSequenceHeader == false, let formatDesc = frame.formatDescription {
                        // Extract AudioSpecificConfig from format description
                        var asc = Data()
                        var size: Int = 0
                        if let cookie = CMAudioFormatDescriptionGetMagicCookie(formatDesc, sizeOut: &size), size > 0 {
                            asc = Data(bytes: cookie, count: size)
                        } else {
                            // Manual ASC construction for AAC-LC 48kHz stereo
                            let byte1: UInt8 = 0x11  // (2<<3)|(3>>1) = AAC-LC, 48kHz
                            let byte2: UInt8 = 0x90  // ((3&1)<<7)|(2<<3) = 48kHz, stereo
                            asc = Data([byte1, byte2])
                        }

                        try await publisher?.sendAudioSequenceHeader(asc: asc)
                        self?.sentAudioSequenceHeader = true
                        print("✅ Sent audio sequence header (ONCE)")
                    }

                    // Send audio frame
                    try await publisher?.send(audio: frame)
                } catch {
                    print("❌ Failed to send audio frame: \(error)")
                }
            }
        }

        streamVideoEncoder = videoEncoder
        streamAudioEncoder = audioEncoder
        rtmpPublisher = publisher
        isStreaming = true
        sentVideoSequenceHeader = false
        sentAudioSequenceHeader = false
        streamStartTime = startTime ?? CMClockGetTime(CMClockGetHostTimeClock())
        lastStreamVideoTimestamp = .zero
        lastStreamAudioTimestamp = .zero

        print("✅ RTMP stream started with video and audio encoding")
    }

    /// Stop streaming
    public func stopStreaming() async {
        guard isStreaming, let publisher = rtmpPublisher else { return }

        print("📡 Stopping RTMP stream...")
        await publisher.disconnect()

        // Stop encoders
        streamVideoEncoder?.stop()
        streamAudioEncoder = nil
        streamVideoEncoder = nil

        rtmpPublisher = nil
        isStreaming = false
        sentVideoSequenceHeader = false
        sentAudioSequenceHeader = false
        streamStartTime = nil

        print("✅ RTMP stream stopped")
    }

    /// Get streaming statistics
    public var streamStatistics: RTMPPublisher.StreamStatistics? {
        get async {
            guard let publisher = rtmpPublisher else { return nil }
            return await publisher.statistics
        }
    }

    // MARK: - VTCompressionSession Setup

    // MARK: - AudioConverter Setup (Disabled - using ArkavoMedia encoders)

    // MARK: - Disabled Audio Conversion (Complex, needs better approach)

    /*
    // TODO: Revisit audio streaming with simpler architecture
    // - Consider AVAudioEngine + AVAudioConverter
    // - Or use separate AVAssetWriterInput for streaming
    // - Or use third-party library like FFmpeg

    private func setupAudioConverter() throws {
        // Input format: PCM 48kHz stereo 16-bit (what we receive from AudioRouter)
        var inputFormat = AudioStreamBasicDescription()
        inputFormat.mSampleRate = 48000.0
        inputFormat.mFormatID = kAudioFormatLinearPCM
        inputFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        inputFormat.mBytesPerPacket = 4  // 2 channels × 2 bytes (16-bit)
        inputFormat.mFramesPerPacket = 1
        inputFormat.mBytesPerFrame = 4
        inputFormat.mChannelsPerFrame = 2
        inputFormat.mBitsPerChannel = 16

        // Output format: AAC-LC 48kHz stereo
        var outputFormat = AudioStreamBasicDescription()
        outputFormat.mSampleRate = 48000.0
        outputFormat.mFormatID = kAudioFormatMPEG4AAC
        outputFormat.mFormatFlags = UInt32(MPEG4ObjectID.AAC_LC.rawValue)  // AAC-LC
        outputFormat.mBytesPerPacket = 0  // Variable (compressed)
        outputFormat.mFramesPerPacket = 1024  // AAC frame size
        outputFormat.mBytesPerFrame = 0  // Variable
        outputFormat.mChannelsPerFrame = 2
        outputFormat.mBitsPerChannel = 0  // Not applicable for compressed

        // Create AudioConverter
        var converter: AudioConverterRef?
        let status = AudioConverterNew(&inputFormat, &outputFormat, &converter)

        guard status == noErr, let converter = converter else {
            print("❌ Failed to create AudioConverter: \(status)")
            throw RecorderError.encodingFailed
        }

        // Set bitrate
        var bitrate = UInt32(audioBitrate)
        AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitrate
        )

        // Set output data quality to high (forces AAC-LC)
        var quality = kAudioConverterQuality_High
        AudioConverterSetProperty(
            converter,
            kAudioConverterCodecQuality,
            UInt32(MemoryLayout<UInt32>.size),
            &quality
        )

        audioConverter = converter
        audioConverterInputFormat = inputFormat
        audioConverterOutputFormat = outputFormat

        // Extract AudioSpecificConfig from the converter
        var asc = Data()
        var ascSize: UInt32 = 0
        AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &ascSize, nil)

        if ascSize > 0 {
            var cookieData = [UInt8](repeating: 0, count: Int(ascSize))
            AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &ascSize, &cookieData)
            asc = Data(cookieData)
            print("🎵 AudioConverter magic cookie (AudioSpecificConfig): \(asc.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }

        print("✅ AudioConverter created: PCM 48kHz stereo → AAC-LC 48kHz stereo, bitrate=\(audioBitrate/1000)kbps")
    }

    /// Convert PCM CMSampleBuffer to AAC CMSampleBuffer for streaming
    private func convertPCMToAAC(_ pcmSampleBuffer: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let converter = audioConverter else {
            throw RecorderError.encodingFailed
        }

        // Extract PCM data from input sample buffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(pcmSampleBuffer) else {
            throw RecorderError.encodingFailed
        }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let pcmData = dataPointer else {
            throw RecorderError.encodingFailed
        }

        // AAC output buffer (allocate max size)
        let maxOutputSize = 2048  // Max AAC frame size
        var outputData = Data(count: maxOutputSize)
        var outputDataSize = UInt32(maxOutputSize)

        // Create audio buffer list for output
        var outputBuffer = AudioBuffer()
        outputBuffer.mNumberChannels = 2
        outputBuffer.mDataByteSize = outputDataSize
        outputData.withUnsafeMutableBytes { ptr in
            outputBuffer.mData = ptr.baseAddress
        }

        var outputBufferList = AudioBufferList()
        outputBufferList.mNumberBuffers = 1
        outputBufferList.mBuffers = outputBuffer

        // Create input data context for callback
        let inputDataPtr = UnsafeMutableRawPointer(mutating: pcmData)
        var inputDataSize = UInt32(length)

        var contextTuple = (inputDataPtr, inputDataSize)

        // Convert PCM to AAC
        let convertStatus = withUnsafeMutablePointer(to: &contextTuple) { contextPtr in
            AudioConverterFillComplexBuffer(
                converter,
                { (inConverter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                    guard let userData = inUserData else { return -1 }
                    let context = userData.assumingMemoryBound(to: (UnsafeMutableRawPointer, UInt32).self).pointee

                    // For stereo 16-bit PCM: 2 channels × 2 bytes = 4 bytes per packet
                    let bytesPerPacket: UInt32 = 4
                    let availablePackets = context.1 / bytesPerPacket

                    // Provide minimum of requested vs available
                    let packetsToProvide = min(ioNumberDataPackets.pointee, availablePackets)

                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mData = context.0
                    ioData.pointee.mBuffers.mDataByteSize = packetsToProvide * bytesPerPacket
                    ioData.pointee.mBuffers.mNumberChannels = 2

                    // CRITICAL: Report actual packet count provided
                    ioNumberDataPackets.pointee = packetsToProvide

                    return noErr
                },
                contextPtr,
                &outputDataSize,
                &outputBufferList,
                nil
            )
        }

        guard convertStatus == noErr else {
            print("❌ Audio conversion failed: \(convertStatus)")
            throw RecorderError.encodingFailed
        }

        // Trim output data to actual size
        outputData = outputData.prefix(Int(outputDataSize))

        print("🎵 Converted PCM (\(length) bytes) → AAC (\(outputData.count) bytes)")

        // Create CMSampleBuffer with AAC data
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: outputData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: outputData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard createStatus == kCMBlockBufferNoErr, let blockBuffer = blockBuffer else {
            throw RecorderError.encodingFailed
        }

        // Copy AAC data into block buffer
        outputData.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: outputData.count
            )
        }

        // Create format description for AAC
        var formatDesc: CMAudioFormatDescription?
        guard let outputFormat = audioConverterOutputFormat else {
            throw RecorderError.encodingFailed
        }

        var asbd = outputFormat
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )

        guard formatStatus == noErr, let formatDesc = formatDesc else {
            throw RecorderError.encodingFailed
        }

        // Create sample buffer with AAC data
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo()
        timingInfo.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(pcmSampleBuffer)
        timingInfo.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(pcmSampleBuffer)
        timingInfo.duration = CMSampleBufferGetDuration(pcmSampleBuffer)

        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            throw RecorderError.encodingFailed
        }

        return sampleBuffer
    }
    */

}

