@preconcurrency import AVFoundation
import CoreVideo
import VideoToolbox
import AudioToolbox
import ArkavoStreaming
import ArkavoMedia

/// Encodes video and audio to MOV files using AVAssetWriter
/// Supports optional simultaneous streaming via RTMP using VTCompressionSession
///
/// Thread Safety: This is an actor to ensure all mutable state is accessed safely.
/// All encoding operations are serialized through the actor's executor.
public actor VideoEncoder {
    // MARK: - Properties

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInputs: [String: AVAssetWriterInput] = [:]  // sourceID -> audio input
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // ArkavoMedia encoders for streaming
    private var streamVideoEncoder: ArkavoMedia.VideoEncoder?
    private var streamAudioEncoder: ArkavoMedia.AudioEncoder?

    private var outputURL: URL?
    private var startTime: CMTime?
    private var lastVideoTimestamp: CMTime = .zero
    private var isPaused: Bool = false
    private var pauseStartTime: CMTime?
    private var totalPausedDuration: CMTime = .zero
    private var sessionStarted: Bool = false

    public private(set) var isRecording: Bool = false

    // Streaming support
    private var rtmpPublisher: RTMPPublisher?
    private var isStreaming: Bool = false
    private var videoFormatDescription: CMFormatDescription?
    private var audioFormatDescription: CMFormatDescription?
    private var sentVideoSequenceHeader: Bool = false
    private var sentAudioSequenceHeader: Bool = false
    private var streamStartTime: CMTime?  // Stream start time for relative timestamps
    private var lastStreamVideoTimestamp: CMTime = .zero  // Last video timestamp sent to stream
    private var lastStreamAudioTimestamp: CMTime = .zero  // Last audio timestamp sent to stream

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
    ///   - videoEnabled: Whether to include video track (false for audio-only recording)
    public func startRecording(to url: URL, title: String, audioSourceIDs: [String] = [], videoEnabled: Bool = true) async throws {
        guard !isRecording else { return }

        outputURL = url

        // Remove existing file if present
        try? FileManager.default.removeItem(at: url)

        // Use appropriate file type: .mov for video, .m4a for audio-only
        let fileType: AVFileType = videoEnabled ? .mov : .m4a

        // Create asset writer
        assetWriter = try AVAssetWriter(url: url, fileType: fileType)

        guard let assetWriter = assetWriter else {
            throw RecorderError.encodingFailed
        }

        // Setup video input only if video is enabled
        if videoEnabled {
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
        } else {
            // Audio-only mode: no video input
            videoInput = nil
            pixelBufferAdaptor = nil
            print("🎵 VideoEncoder: Audio-only mode enabled (no video track)")
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
        sessionStarted = false
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

        // Handle based on session and writer state
        if !sessionStarted {
            print("⚠️ No frames were written (session never started), cancelling asset writer")
            assetWriter.cancelWriting()
        } else if assetWriter.status == .writing {
            print("📝 Marking inputs as finished...")

            // Always mark inputs as finished before finishWriting()
            // Don't check isReadyForMoreMediaData - just mark them finished
            if let videoInput = videoInput {
                videoInput.markAsFinished()
                print("  ✓ Video input marked as finished")
            }

            // Mark all audio inputs as finished
            for (sourceID, audioInput) in audioInputs {
                audioInput.markAsFinished()
                print("  ✓ Audio input [\(sourceID)] marked as finished")
            }

            // Finish writing - this writes the moov atom
            print("⏳ Finishing asset writer...")
            await assetWriter.finishWriting()
            print("✅ Asset writer finished with status: \(assetWriter.status.rawValue)")

            // Verify completion
            if assetWriter.status != .completed {
                print("❌ Asset writer did not complete successfully: \(assetWriter.status.rawValue)")
                if let error = assetWriter.error {
                    print("   Error: \(error.localizedDescription)")
                }
            }
        } else if assetWriter.status == .failed {
            print("❌ Asset writer already failed: \(assetWriter.error?.localizedDescription ?? "Unknown")")
            // Don't call finishWriting on failed writer, just throw below
        } else {
            // Status is .unknown, .cancelled, or .completed already
            print("⚠️ Asset writer in unexpected state: \(assetWriter.status.rawValue), attempting to finish anyway")
            // Try to finish if possible - better than leaving file corrupted
            if assetWriter.status != .cancelled && assetWriter.status != .completed {
                if let videoInput = videoInput {
                    videoInput.markAsFinished()
                }
                for (_, audioInput) in audioInputs {
                    audioInput.markAsFinished()
                }
                await assetWriter.finishWriting()
                print("  Finish attempt completed with status: \(assetWriter.status.rawValue)")
            }
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
        guard startTime != nil else { return 0 }
        // lastVideoTimestamp is already normalized to start at zero
        let finalDuration = CMTimeSubtract(lastVideoTimestamp, totalPausedDuration)
        return CMTimeGetSeconds(finalDuration)
    }

    // MARK: - Frame Encoding

    /// Encodes a video frame
    public func encodeVideoFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard isRecording, !isPaused else { return }
        guard let videoInput = videoInput, let adaptor = pixelBufferAdaptor else { return }
        guard let assetWriter = assetWriter else { return }

        // Validate timestamp
        guard timestamp.isValid, timestamp.seconds >= 0 else {
            print("⚠️ Invalid timestamp: \(timestamp)")
            return
        }

        // Check if asset writer is ready for writing
        guard assetWriter.status == .writing else {
            if assetWriter.status == .failed {
                print("❌ Asset writer failed before encoding could start")
            }
            return
        }

        // Initialize session on first frame (thread-safe check)
        if !sessionStarted {
            sessionStarted = true
            startTime = timestamp
            // Start session at time zero - we'll normalize all timestamps
            assetWriter.startSession(atSourceTime: .zero)
            lastVideoTimestamp = .zero
            print("📹 VideoEncoder: Session started, base timestamp \(timestamp.seconds)")
        }

        // Wait if input is not ready
        if !videoInput.isReadyForMoreMediaData {
            return
        }

        // Double-check asset writer is still healthy
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

        // Normalize timestamp relative to recording start
        guard let baseTime = startTime else { return }
        var adjustedTimestamp = CMTimeSubtract(timestamp, baseTime)

        // Skip frames from before recording started (can happen with preview running)
        if adjustedTimestamp.seconds < 0 {
            return
        }

        // Adjust for pauses
        if !totalPausedDuration.seconds.isZero {
            adjustedTimestamp = CMTimeSubtract(adjustedTimestamp, totalPausedDuration)
        }

        // Ensure timestamps are monotonically increasing
        if CMTimeCompare(adjustedTimestamp, lastVideoTimestamp) <= 0 {
            // Timestamp is not increasing, skip this frame
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
                streamFrameCount += 1
                if streamFrameCount % 30 == 0 {
                    print("📊 Fed frame #\(streamFrameCount) to stream encoder at \(adjustedTimestamp.seconds)s")
                }
            } catch {
                print("❌ Stream video encoder failed: \(error)")
            }
        }
    }

    private var streamFrameCount: Int = 0

    /// Encodes an audio sample from a specific source
    /// - Parameters:
    ///   - sampleBuffer: Audio sample buffer (must be 48kHz PCM stereo)
    ///   - sourceID: Unique identifier for the audio source (e.g., "microphone", "screen", "remote-camera-123")
    public func encodeAudioSample(_ sampleBuffer: CMSampleBuffer, sourceID: String) {
        // Allow audio processing if either recording OR streaming
        guard (isRecording || isStreaming) && !isPaused else { return }

        guard CMSampleBufferIsValid(sampleBuffer) else {
            return
        }

        // Handle file recording if active
        if isRecording {
            guard let writer = assetWriter, writer.status == .writing else {
                return
            }

            // For audio-only mode (no video input), start session on first audio sample
            let isAudioOnly = videoInput == nil
            if isAudioOnly && !sessionStarted {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                sessionStarted = true
                startTime = timestamp
                writer.startSession(atSourceTime: .zero)
                print("🎵 VideoEncoder: Audio-only session started, base timestamp \(timestamp.seconds)")
            }

            // Wait for session to start (video will start it normally, or audio-only above)
            guard startTime != nil else {
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

            // Normalize audio timestamp relative to recording start (same as video)
            guard let baseTime = startTime else { return }
            let originalTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            var adjustedTimestamp = CMTimeSubtract(originalTimestamp, baseTime)

            // Skip audio from before recording started
            if adjustedTimestamp.seconds < 0 {
                return
            }

            // Adjust for pauses
            if !totalPausedDuration.seconds.isZero {
                adjustedTimestamp = CMTimeSubtract(adjustedTimestamp, totalPausedDuration)
            }

            // Create adjusted sample buffer with normalized timing
            var adjustedBuffer: CMSampleBuffer?
            var timingInfo = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: adjustedTimestamp,
                decodeTimeStamp: .invalid
            )

            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleBufferOut: &adjustedBuffer
            )

            guard status == noErr, let finalBuffer = adjustedBuffer else {
                print("⚠️ Failed to create adjusted audio buffer")
                return
            }

            // Append audio sample to file
            // AVAssetWriterInput will automatically encode PCM to AAC
            if !audioInput.append(finalBuffer) {
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
    public func encodeAudioSample(_ sampleBuffer: CMSampleBuffer) {
        encodeAudioSample(sampleBuffer, sourceID: "microphone")
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

    // Frame queue continuations for serialized sending
    private var videoFrameContinuation: AsyncStream<EncodedVideoFrame>.Continuation?
    private var audioFrameContinuation: AsyncStream<EncodedAudioFrame>.Continuation?
    private var videoSendTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?

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

        // Create AsyncStreams to serialize frame sending (prevents burst/out-of-order issues)
        let (videoStream, videoContinuation) = AsyncStream<EncodedVideoFrame>.makeStream()
        let (audioStream, audioContinuation) = AsyncStream<EncodedAudioFrame>.makeStream()
        self.videoFrameContinuation = videoContinuation
        self.audioFrameContinuation = audioContinuation

        // Wire up video encoder callback - just queue frames
        // Capture continuation locally to avoid actor isolation issues
        let videoCont = videoContinuation
        videoEncoder.onFrame = { frame in
            videoCont.yield(frame)
        }

        // Wire up audio encoder callback - just queue frames
        let audioCont = audioContinuation
        audioEncoder.onFrame = { frame in
            audioCont.yield(frame)
        }

        // Start video send task - serializes frame sending
        // Frames arrive from camera at realtime pace, so we just need to send them in order
        // without additional pacing (the camera/encoder already gates the frame rate)
        videoSendTask = Task { [weak self, weak publisher] in
            for await frame in videoStream {
                guard let self = self, let publisher = publisher else { break }
                guard !Task.isCancelled else { break }

                do {
                    // Send sequence header ONLY ONCE on first keyframe
                    let needsHeader = await self.shouldSendVideoSequenceHeader()
                    if frame.isKeyframe, needsHeader, let formatDesc = frame.formatDescription {
                        try await publisher.sendVideoSequenceHeader(formatDescription: formatDesc)
                        await self.markVideoSequenceHeaderSent()
                        print("✅ Sent video sequence header (ONCE)")
                    }

                    // Send video frame immediately - frames arrive at realtime from camera
                    try await publisher.send(video: frame)
                } catch is CancellationError {
                    break
                } catch {
                    print("❌ Failed to send video frame: \(error)")
                }
            }
        }

        // Start audio send task - serializes frame sending
        // Audio frames arrive from encoder at realtime pace
        audioSendTask = Task { [weak self, weak publisher] in
            for await frame in audioStream {
                guard let self = self, let publisher = publisher else { break }
                guard !Task.isCancelled else { break }

                do {
                    // Send sequence header ONLY ONCE on first frame
                    let needsHeader = await self.shouldSendAudioSequenceHeader()
                    if needsHeader, let formatDesc = frame.formatDescription {
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

                        try await publisher.sendAudioSequenceHeader(asc: asc)
                        await self.markAudioSequenceHeaderSent()
                        print("✅ Sent audio sequence header (ONCE)")
                    }

                    // Send audio frame immediately - frames arrive at realtime from encoder
                    try await publisher.send(audio: frame)
                } catch is CancellationError {
                    break
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

        // Finish the frame queues first
        videoFrameContinuation?.finish()
        audioFrameContinuation?.finish()
        videoFrameContinuation = nil
        audioFrameContinuation = nil

        // Wait for send tasks to complete
        videoSendTask?.cancel()
        audioSendTask?.cancel()
        videoSendTask = nil
        audioSendTask = nil

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

    // MARK: - Sequence Header State Helpers (for actor-safe callback access)

    /// Returns true if video sequence header has not yet been sent
    private func shouldSendVideoSequenceHeader() -> Bool {
        !sentVideoSequenceHeader
    }

    /// Marks video sequence header as sent
    private func markVideoSequenceHeaderSent() {
        sentVideoSequenceHeader = true
    }

    /// Returns true if audio sequence header has not yet been sent
    private func shouldSendAudioSequenceHeader() -> Bool {
        !sentAudioSequenceHeader
    }

    /// Marks audio sequence header as sent
    private func markAudioSequenceHeaderSent() {
        sentAudioSequenceHeader = true
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

