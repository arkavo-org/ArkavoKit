import AVFoundation
import CoreMedia

/// Converts audio samples from one format to another using AVAudioConverter
public class AudioFormatConverter {
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let sourceID: String

    /// Initialize with target output format
    /// - Parameters:
    ///   - targetSampleRate: Desired sample rate (e.g., 48000.0)
    ///   - targetChannels: Desired channel count (e.g., 2 for stereo)
    ///   - sourceID: Identifier for logging purposes
    public init(targetSampleRate: Double, targetChannels: UInt32, sourceID: String) {
        self.sourceID = sourceID

        // Create target format: Linear PCM for intermediate processing before AAC encoding
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(targetChannels),
            interleaved: true
        ) else {
            fatalError("Failed to create target audio format")
        }

        self.targetFormat = format
        print("🎵 AudioFormatConverter [\(sourceID)] initialized: target \(targetSampleRate)Hz, \(targetChannels)ch")
    }

    /// Convert a CMSampleBuffer to the target format
    /// - Parameter sampleBuffer: Input sample buffer in any supported format
    /// - Returns: Converted sample buffer in target format, or nil if conversion fails
    public func convert(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        // Get source format
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            print("⚠️ AudioFormatConverter [\(sourceID)]: Failed to get format description")
            return nil
        }

        // Create source AVAudioFormat
        var mutableASBD = asbd
        guard let sourceFormat = AVAudioFormat(streamDescription: &mutableASBD) else {
            print("⚠️ AudioFormatConverter [\(sourceID)]: Failed to create source AVAudioFormat")
            return nil
        }

        // Check if conversion is needed
        if sourceFormat.sampleRate == targetFormat.sampleRate &&
           sourceFormat.channelCount == targetFormat.channelCount &&
           sourceFormat.commonFormat == targetFormat.commonFormat {
            // No conversion needed
            return sampleBuffer
        }

        // Create or reuse converter
        if converter == nil || converter?.inputFormat != sourceFormat {
            guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                print("⚠️ AudioFormatConverter [\(sourceID)]: Failed to create converter from \(sourceFormat.sampleRate)Hz to \(targetFormat.sampleRate)Hz")
                return nil
            }
            converter = newConverter
            print("🔄 AudioFormatConverter [\(sourceID)]: Created converter \(sourceFormat.sampleRate)Hz → \(targetFormat.sampleRate)Hz, \(sourceFormat.channelCount)→\(targetFormat.channelCount)ch")
        }

        guard let converter = converter else { return nil }

        // Extract audio buffer from CMSampleBuffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            print("⚠️ AudioFormatConverter [\(sourceID)]: Failed to get data buffer")
            return nil
        }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard status == noErr, let data = dataPointer else {
            print("⚠️ AudioFormatConverter [\(sourceID)]: Failed to get data pointer")
            return nil
        }

        // Calculate frame count
        let bytesPerFrame = sourceFormat.streamDescription.pointee.mBytesPerFrame
        let frameCount = AVAudioFrameCount(length) / AVAudioFrameCount(bytesPerFrame)

        // Create source PCM buffer
        guard let sourcePCMBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            print("⚠️ AudioFormatConverter [\(sourceID)]: Failed to create source PCM buffer")
            return nil
        }
        sourcePCMBuffer.frameLength = frameCount

        // Copy data to PCM buffer
        let audioBufferList = sourcePCMBuffer.mutableAudioBufferList.pointee
        memcpy(audioBufferList.mBuffers.mData, data, Int(length))

        // Calculate output frame capacity (may differ due to sample rate conversion)
        let outputFrameCapacity = AVAudioFrameCount(Double(frameCount) * (targetFormat.sampleRate / sourceFormat.sampleRate)) + 1

        // Create destination PCM buffer
        guard let destinationPCMBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            print("⚠️ AudioFormatConverter [\(sourceID)]: Failed to create destination PCM buffer")
            return nil
        }

        // Perform conversion
        var error: NSError?
        // Note: sourcePCMBuffer is captured but used synchronously, so it's safe despite not being Sendable
        nonisolated(unsafe) let buffer = sourcePCMBuffer
        let inputBlock: AVAudioConverterInputBlock = { @Sendable inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let conversionStatus = converter.convert(to: destinationPCMBuffer, error: &error, withInputFrom: inputBlock)

        guard conversionStatus != AVAudioConverterOutputStatus.error, error == nil else {
            print("⚠️ AudioFormatConverter [\(sourceID)]: Conversion failed: \(error?.localizedDescription ?? "unknown error")")
            return nil
        }

        // Convert PCM buffer back to CMSampleBuffer
        guard let convertedSampleBuffer = createCMSampleBuffer(from: destinationPCMBuffer, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else {
            print("⚠️ AudioFormatConverter [\(sourceID)]: Failed to create CMSampleBuffer from converted PCM")
            return nil
        }

        return convertedSampleBuffer
    }

    /// Create a CMSampleBuffer from an AVAudioPCMBuffer
    private func createCMSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, presentationTimeStamp: CMTime) -> CMSampleBuffer? {
        let audioBufferList = pcmBuffer.audioBufferList.pointee
        let frameCount = Int(pcmBuffer.frameLength)

        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: pcmBuffer.format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard formatStatus == noErr, let formatDesc = formatDescription else {
            print("⚠️ AudioFormatConverter [\(sourceID)]: Failed to create format description")
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleBufferStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleBufferStatus == noErr, let buffer = sampleBuffer else {
            print("⚠️ AudioFormatConverter [\(sourceID)]: Failed to create sample buffer")
            return nil
        }

        var mutableAudioBufferList = audioBufferList
        let bufferListStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: &mutableAudioBufferList
        )

        guard bufferListStatus == noErr else {
            print("⚠️ AudioFormatConverter [\(sourceID)]: Failed to set data buffer")
            return nil
        }

        return buffer
    }
}
