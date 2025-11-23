import AVFoundation
import CoreMedia
import AudioToolbox

/// Hardware-accelerated AAC audio encoder for streaming
/// Buffers incoming PCM samples and outputs AAC frames
public final class AudioEncoder: Sendable {
    // MARK: - Types

    public enum EncoderError: Error {
        case converterCreationFailed
        case bufferCreationFailed
        case conversionFailed(OSStatus)
        case invalidInput
    }

    // MARK: - Properties

    nonisolated(unsafe) private let converter: AVAudioConverter
    nonisolated(unsafe) private let pcmFormat: AVAudioFormat
    nonisolated(unsafe) private let aacFormat: AVAudioFormat
    nonisolated(unsafe) private var inputBuffer: AVAudioPCMBuffer
    nonisolated(unsafe) private var inputBufferFrameCount: AVAudioFrameCount = 0

    private let targetFrameCount: AVAudioFrameCount = 1024  // AAC frame size
    private let sampleRate: Double = 48000
    private let channelCount: AVAudioChannelCount = 2
    private let bitrate: Int

    /// Callback invoked when an AAC frame is ready
    nonisolated(unsafe) public var onFrame: (@Sendable (EncodedAudioFrame) -> Void)?

    // MARK: - Initialization

    public init(bitrate: Int = 128_000) throws {
        self.bitrate = bitrate

        // Create PCM format (48kHz stereo 16-bit)
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: true
        ) else {
            throw EncoderError.converterCreationFailed
        }
        self.pcmFormat = pcmFormat

        // Create AAC format (48kHz stereo)
        var aacASBD = AudioStreamBasicDescription()
        aacASBD.mSampleRate = sampleRate
        aacASBD.mFormatID = kAudioFormatMPEG4AAC
        aacASBD.mFormatFlags = UInt32(MPEG4ObjectID.AAC_LC.rawValue)
        aacASBD.mFramesPerPacket = 1024
        aacASBD.mChannelsPerFrame = channelCount

        guard let aacFormat = AVAudioFormat(streamDescription: &aacASBD) else {
            throw EncoderError.converterCreationFailed
        }
        self.aacFormat = aacFormat

        // Create converter
        guard let converter = AVAudioConverter(from: pcmFormat, to: aacFormat) else {
            throw EncoderError.converterCreationFailed
        }
        self.converter = converter

        // Set bitrate
        converter.bitRate = bitrate

        // Create input buffer (hold up to 2 AAC frames worth of PCM)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: targetFrameCount * 2
        ) else {
            throw EncoderError.bufferCreationFailed
        }
        self.inputBuffer = inputBuffer

        print("✅ AudioEncoder initialized: PCM 48kHz stereo → AAC-LC \(bitrate/1000)kbps")
    }

    // MARK: - Public Methods

    /// Feed PCM audio samples for encoding
    /// - Parameters:
    ///   - sampleBuffer: PCM audio sample buffer
    ///   - timestamp: Presentation timestamp
    public func feed(_ sampleBuffer: CMSampleBuffer) {
        // Extract PCM data from CMSampleBuffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            print("❌ AudioEncoder: No data buffer")
            return
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
            print("❌ AudioEncoder: Failed to get data pointer")
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Calculate frame count (stereo 16-bit = 4 bytes per frame)
        let bytesPerFrame = Int(pcmFormat.streamDescription.pointee.mBytesPerFrame)
        let frameCount = AVAudioFrameCount(length / bytesPerFrame)

        // Append to input buffer
        appendToBuffer(pcmData: pcmData, frameCount: frameCount, timestamp: timestamp)
    }

    // MARK: - Private Methods

    private func appendToBuffer(pcmData: UnsafeMutablePointer<Int8>, frameCount: AVAudioFrameCount, timestamp: CMTime) {
        // Check if we have space in the buffer
        let availableSpace = inputBuffer.frameCapacity - inputBufferFrameCount

        guard availableSpace >= frameCount else {
            print("⚠️ AudioEncoder: Buffer full, dropping \(frameCount) frames")
            return
        }

        // Copy PCM data into buffer
        let channelData = inputBuffer.int16ChannelData!
        let destPointer = channelData[0].advanced(by: Int(inputBufferFrameCount) * Int(channelCount))
        let bytesToCopy = Int(frameCount) * Int(pcmFormat.streamDescription.pointee.mBytesPerFrame)

        pcmData.withMemoryRebound(to: Int16.self, capacity: bytesToCopy / 2) { srcPointer in
            destPointer.update(from: srcPointer, count: bytesToCopy / 2)
        }

        inputBufferFrameCount += frameCount

        // If we have enough frames, encode
        if inputBufferFrameCount >= targetFrameCount {
            encodeAccumulatedFrames(timestamp: timestamp)
        }
    }

    private func encodeAccumulatedFrames(timestamp: CMTime) {
        // Update buffer frame length to actual accumulated count
        inputBuffer.frameLength = inputBufferFrameCount

        // Create output buffer for AAC
        let outputBuffer = AVAudioCompressedBuffer(
            format: aacFormat,
            packetCapacity: 1,
            maximumPacketSize: 2048  // Max AAC frame size
        )

        // Convert PCM → AAC
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return self.inputBuffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        guard status != .error, error == nil else {
            print("❌ AudioEncoder: Conversion failed: \(error?.localizedDescription ?? "unknown")")
            return
        }

        // Extract AAC data
        if let packetDescriptions = outputBuffer.packetDescriptions,
           outputBuffer.packetCount > 0 {
            let packetDesc = packetDescriptions[0]
            let aacData = Data(bytes: outputBuffer.data.advanced(by: Int(packetDesc.mStartOffset)),
                              count: Int(packetDesc.mDataByteSize))

            // Create format description for AAC
            let formatDesc = createAACFormatDescription()

            // Emit encoded frame
            let frame = EncodedAudioFrame(
                data: aacData,
                pts: timestamp,
                formatDescription: formatDesc
            )

            onFrame?(frame)

            // Removed excessive logging - frame encoding is normal operation
        }

        // Reset buffer for next accumulation
        inputBufferFrameCount = 0
        inputBuffer.frameLength = 0
    }

    private func createAACFormatDescription() -> CMAudioFormatDescription? {
        // Create AudioSpecificConfig for AAC-LC 48kHz stereo
        // Format: 5 bits object type (2=AAC-LC) + 4 bits sample rate index (3=48kHz) + 4 bits channel config (2=stereo)
        let objectType: UInt8 = 2  // AAC-LC
        let srIndex: UInt8 = 3     // 48kHz
        let channelConfig: UInt8 = 2  // Stereo

        let byte1 = (objectType << 3) | (srIndex >> 1)
        let byte2 = ((srIndex & 0x01) << 7) | (channelConfig << 3)

        let asc = Data([byte1, byte2])

        // Create format description
        var formatDesc: CMAudioFormatDescription?
        var asbd = aacFormat.streamDescription.pointee

        let status = asc.withUnsafeBytes { ascBytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: ascBytes.count,
                magicCookie: ascBytes.baseAddress,
                extensions: nil,
                formatDescriptionOut: &formatDesc
            )
        }

        guard status == noErr else {
            print("❌ AudioEncoder: Failed to create format description: \(status)")
            return nil
        }

        return formatDesc
    }
}
