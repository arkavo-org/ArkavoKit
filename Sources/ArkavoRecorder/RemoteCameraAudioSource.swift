import AVFoundation
import CoreMedia

/// Audio source for remote camera audio received over the network
public final class RemoteCameraAudioSource: AudioSource {
    // MARK: - AudioSource Protocol

    public let sourceID: String
    public let sourceName: String

    nonisolated(unsafe) public private(set) var format: AudioFormat

    nonisolated(unsafe) public private(set) var isActive: Bool = false

    nonisolated(unsafe) public var onSample: ((CMSampleBuffer) -> Void)?

    // MARK: - Properties

    nonisolated(unsafe) private var referenceTime: CMTime?
    nonisolated(unsafe) private var formatDescription: CMAudioFormatDescription?

    // MARK: - Initialization

    /// Initialize with remote camera source info
    /// - Parameters:
    ///   - sourceID: Unique identifier for this remote camera
    ///   - sourceName: Human-readable name (e.g., "Remote Camera - iPhone 15")
    ///   - initialFormat: Initial audio format (may be updated when first audio packet arrives)
    public init(sourceID: String, sourceName: String, initialFormat: AudioFormat? = nil) {
        self.sourceID = sourceID
        self.sourceName = sourceName

        // Default format, will be updated when actual audio arrives
        self.format = initialFormat ?? AudioFormat(
            sampleRate: 48000.0,
            channels: 2,
            bitDepth: 16,
            formatID: kAudioFormatLinearPCM
        )

        print("📡 RemoteCameraAudioSource [\(sourceID)] initialized: \(sourceName)")
    }

    // MARK: - AudioSource Protocol Methods

    public func start() async throws {
        isActive = true
        print("📡 RemoteCameraAudioSource [\(sourceID)] started")
    }

    public func stop() async throws {
        isActive = false
        referenceTime = nil
        formatDescription = nil
        print("📡 RemoteCameraAudioSource [\(sourceID)] stopped")
    }

    // MARK: - Public Methods

    /// Process an audio payload received from the remote camera
    /// - Parameter payload: AudioPayload from RemoteCameraMessage
    public func processAudioPayload(_ payload: RemoteCameraMessage.AudioPayload) {
        guard isActive else {
            print("⚠️ RemoteCameraAudioSource [\(sourceID)]: Received audio while not active")
            return
        }

        // Update format if it changed
        let newFormat = AudioFormat(
            sampleRate: payload.sampleRate,
            channels: UInt32(payload.channels),
            bitDepth: 16, // Assuming 16-bit PCM
            formatID: kAudioFormatLinearPCM
        )

        if newFormat.sampleRate != format.sampleRate || newFormat.channels != format.channels {
            print("🔄 RemoteCameraAudioSource [\(sourceID)]: Format changed to \(newFormat.sampleRate)Hz, \(newFormat.channels)ch")
            format = newFormat
            formatDescription = nil // Force recreation
        }

        // Create format description if needed
        if formatDescription == nil {
            formatDescription = createFormatDescription(for: format)
        }

        guard let formatDesc = formatDescription else {
            print("⚠️ RemoteCameraAudioSource [\(sourceID)]: Failed to create format description")
            return
        }

        // Convert timestamp to CMTime
        let presentationTime = CMTime(seconds: payload.timestamp, preferredTimescale: 1_000_000)

        // Create CMSampleBuffer from audio data
        guard let sampleBuffer = createSampleBuffer(
            from: payload.audioData,
            formatDescription: formatDesc,
            presentationTime: presentationTime
        ) else {
            print("⚠️ RemoteCameraAudioSource [\(sourceID)]: Failed to create sample buffer")
            return
        }

        // Forward sample
        onSample?(sampleBuffer)
    }

    // MARK: - Private Methods

    private func createFormatDescription(for format: AudioFormat) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = format.sampleRate
        asbd.mFormatID = format.formatID
        asbd.mChannelsPerFrame = format.channels
        asbd.mBitsPerChannel = format.bitDepth
        asbd.mBytesPerFrame = (format.bitDepth / 8) * format.channels
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerPacket = asbd.mBytesPerFrame * asbd.mFramesPerPacket
        asbd.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked

        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )

        guard status == noErr else {
            print("⚠️ RemoteCameraAudioSource [\(sourceID)]: Failed to create format description, status: \(status)")
            return nil
        }

        return formatDesc
    }

    private func createSampleBuffer(
        from audioData: Data,
        formatDescription: CMAudioFormatDescription,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return nil
        }

        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let frameCount = audioData.count / bytesPerFrame

        var blockBuffer: CMBlockBuffer?
        var blockBufferStatus: OSStatus = noErr

        audioData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else {
                blockBufferStatus = -1
                return
            }

            blockBufferStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: audioData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: audioData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard blockBufferStatus == noErr, let blockBuffer = blockBuffer else {
                return
            }

            blockBufferStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: audioData.count
            )
        }

        guard blockBufferStatus == noErr, let blockBuffer = blockBuffer else {
            print("⚠️ RemoteCameraAudioSource [\(sourceID)]: Failed to create block buffer, status: \(blockBufferStatus)")
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleBufferStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleBufferStatus == noErr else {
            print("⚠️ RemoteCameraAudioSource [\(sourceID)]: Failed to create sample buffer, status: \(sampleBufferStatus)")
            return nil
        }

        return sampleBuffer
    }
}
