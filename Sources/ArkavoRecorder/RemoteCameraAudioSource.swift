import AVFoundation
import CoreMedia
import os

/// Audio source for remote camera audio received over the network
public final class RemoteCameraAudioSource: AudioSource, @unchecked Sendable {
    // MARK: - AudioSource Protocol

    public let sourceID: String
    public let sourceName: String

    public var format: AudioFormat {
        state.withLockUnchecked { $0.format }
    }

    public var isActive: Bool {
        state.withLockUnchecked { $0.isActive }
    }

    public var onSample: ((CMSampleBuffer) -> Void)? {
        get { state.withLockUnchecked { $0.onSample } }
        set { state.withLockUnchecked { $0.onSample = newValue } }
    }

    // MARK: - Properties

    private struct SharedState {
        var format: AudioFormat
        var isActive: Bool = false
        var onSample: ((CMSampleBuffer) -> Void)?
        var referenceTime: CMTime?
        var formatDescription: CMAudioFormatDescription?
    }

    private let state: OSAllocatedUnfairLock<SharedState>

    private static let validChannelRange = 1...8
    private static let validSampleRateRange: ClosedRange<Double> = 8_000...192_000

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
        let defaultFormat = initialFormat ?? AudioFormat(
            sampleRate: 48000.0,
            channels: 2,
            bitDepth: 16,
            formatID: kAudioFormatLinearPCM
        )
        self.state = OSAllocatedUnfairLock(uncheckedState: SharedState(format: defaultFormat))

        print("📡 RemoteCameraAudioSource [\(sourceID)] initialized: \(sourceName)")
    }

    // MARK: - AudioSource Protocol Methods

    public func start() async throws {
        state.withLockUnchecked { $0.isActive = true }
        print("📡 RemoteCameraAudioSource [\(sourceID)] started")
    }

    public func stop() async throws {
        state.withLockUnchecked { state in
            state.isActive = false
            state.referenceTime = nil
            state.formatDescription = nil
        }
        print("📡 RemoteCameraAudioSource [\(sourceID)] stopped")
    }

    // MARK: - Public Methods

    /// Process an audio payload received from the remote camera
    /// - Parameter payload: AudioPayload from RemoteCameraMessage
    public func processAudioPayload(_ payload: RemoteCameraMessage.AudioPayload) {
        guard state.withLockUnchecked({ $0.isActive }) else {
            print("⚠️ RemoteCameraAudioSource [\(sourceID)]: Received audio while not active")
            return
        }

        // Validate untrusted network fields before integer casts or frame math
        guard Self.validChannelRange.contains(payload.channels),
              payload.sampleRate.isFinite, Self.validSampleRateRange.contains(payload.sampleRate),
              payload.timestamp.isFinite,
              !payload.audioData.isEmpty
        else {
            print("⚠️ RemoteCameraAudioSource [\(sourceID)]: Rejecting invalid audio payload (channels=\(payload.channels), sampleRate=\(payload.sampleRate), bytes=\(payload.audioData.count))")
            return
        }

        let bitDepth: UInt32 = 16 // Assuming 16-bit PCM
        let channels = UInt32(payload.channels)
        let (bytesPerFrame, overflow) = (bitDepth / 8).multipliedReportingOverflow(by: channels)
        guard !overflow, bytesPerFrame > 0 else { return }

        let newFormat = AudioFormat(
            sampleRate: payload.sampleRate,
            channels: channels,
            bitDepth: bitDepth,
            formatID: kAudioFormatLinearPCM
        )

        let (formatDesc, callback): (CMAudioFormatDescription?, ((CMSampleBuffer) -> Void)?) = state.withLockUnchecked { state in
            guard state.isActive else { return (nil, nil) }

            if newFormat.sampleRate != state.format.sampleRate || newFormat.channels != state.format.channels {
                print("🔄 RemoteCameraAudioSource [\(sourceID)]: Format changed to \(newFormat.sampleRate)Hz, \(newFormat.channels)ch")
                state.format = newFormat
                state.formatDescription = nil // Force recreation
            }

            if state.formatDescription == nil {
                state.formatDescription = createFormatDescription(for: state.format)
            }

            return (state.formatDescription, state.onSample)
        }

        guard let formatDesc else {
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
        callback?(sampleBuffer)
    }

    // MARK: - Private Methods

    private func createFormatDescription(for format: AudioFormat) -> CMAudioFormatDescription? {
        guard format.sampleRate.isFinite, Self.validSampleRateRange.contains(format.sampleRate),
              format.channels >= 1, format.channels <= UInt32(Self.validChannelRange.upperBound),
              format.bitDepth >= 8
        else {
            return nil
        }

        let (bytesPerFrame, overflow) = (format.bitDepth / 8).multipliedReportingOverflow(by: format.channels)
        guard !overflow, bytesPerFrame > 0 else {
            return nil
        }

        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = format.sampleRate
        asbd.mFormatID = format.formatID
        asbd.mChannelsPerFrame = format.channels
        asbd.mBitsPerChannel = format.bitDepth
        asbd.mBytesPerFrame = bytesPerFrame
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerPacket = bytesPerFrame
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
        guard !audioData.isEmpty,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else {
            return nil
        }

        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }

        let frameCount = audioData.count / bytesPerFrame
        guard frameCount > 0 else { return nil }
        let byteCount = frameCount * bytesPerFrame

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
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
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
                dataLength: byteCount
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
