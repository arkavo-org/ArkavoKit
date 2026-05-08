import AVFoundation
import CoreMedia
import AudioToolbox
import Synchronization

/// Hardware-accelerated AAC audio encoder for streaming
/// Buffers incoming PCM samples and outputs AAC frames.
///
/// Thread safety: all `feed(...)` calls and `onFrame` access are serialized through
/// an internal Mutex. Multiple producers (e.g. real microphone audio + a silent-audio
/// fallback task) may call `feed` concurrently and the AAC output stream remains
/// well-ordered for a single bitstream.
public final class AudioEncoder: @unchecked Sendable {
    // MARK: - Types

    public enum EncoderError: Error {
        case converterCreationFailed
        case bufferCreationFailed
        case conversionFailed(OSStatus)
        case invalidInput
    }

    // MARK: - Internal State (all access goes through `state` Mutex)

    private struct State: ~Copyable {
        var inputBufferFrameCount: AVAudioFrameCount = 0
        var onFrame: (@Sendable (EncodedAudioFrame) -> Void)?
    }

    private let state = Mutex(State())

    // Set in init, immutable thereafter — safe to read without locking.
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let aacFormat: AVAudioFormat
    private let inputBuffer: AVAudioPCMBuffer

    private let targetFrameCount: AVAudioFrameCount = 1024  // AAC frame size
    private let sampleRate: Double = 48000
    private let channelCount: AVAudioChannelCount = 2
    private let bitrate: Int

    /// Callback invoked when an AAC frame is ready. Setter and getter are
    /// serialized through the internal Mutex.
    public var onFrame: (@Sendable (EncodedAudioFrame) -> Void)? {
        get { state.withLock { $0.onFrame } }
        set { state.withLock { $0.onFrame = newValue } }
    }

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

    /// Feed PCM audio samples for encoding.
    /// Concurrent calls from multiple tasks are safe; they serialize through an internal lock.
    /// - Parameters:
    ///   - sampleBuffer: PCM audio sample buffer
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

        // Append to input buffer + encode under the lock so concurrent feeds can't
        // corrupt the input PCM buffer or the AVAudioConverter's internal state.
        let frame: EncodedAudioFrame? = state.withLock { state in
            self.appendAndMaybeEncode(
                state: &state,
                pcmData: pcmData,
                frameCount: frameCount,
                timestamp: timestamp
            )
        }
        if let frame, let cb = state.withLock({ $0.onFrame }) {
            cb(frame)
        }
    }

    // MARK: - Private Methods

    /// Append PCM into the input buffer; if we have enough frames, run the converter
    /// and return the resulting AAC frame. Caller must hold the state lock.
    private func appendAndMaybeEncode(
        state: inout State,
        pcmData: UnsafeMutablePointer<Int8>,
        frameCount: AVAudioFrameCount,
        timestamp: CMTime
    ) -> EncodedAudioFrame? {
        let availableSpace = inputBuffer.frameCapacity - state.inputBufferFrameCount
        guard availableSpace >= frameCount else {
            print("⚠️ AudioEncoder: Buffer full, dropping \(frameCount) frames")
            return nil
        }

        // Copy PCM data into buffer
        let channelData = inputBuffer.int16ChannelData!
        let destPointer = channelData[0].advanced(by: Int(state.inputBufferFrameCount) * Int(channelCount))
        let bytesToCopy = Int(frameCount) * Int(pcmFormat.streamDescription.pointee.mBytesPerFrame)

        pcmData.withMemoryRebound(to: Int16.self, capacity: bytesToCopy / 2) { srcPointer in
            destPointer.update(from: srcPointer, count: bytesToCopy / 2)
        }

        state.inputBufferFrameCount += frameCount

        guard state.inputBufferFrameCount >= targetFrameCount else { return nil }

        return encodeAccumulatedFrames(state: &state, timestamp: timestamp)
    }

    private func encodeAccumulatedFrames(state: inout State, timestamp: CMTime) -> EncodedAudioFrame? {
        // Update buffer frame length to actual accumulated count
        inputBuffer.frameLength = state.inputBufferFrameCount

        // Create output buffer for AAC
        let outputBuffer = AVAudioCompressedBuffer(
            format: aacFormat,
            packetCapacity: 1,
            maximumPacketSize: 2048  // Max AAC frame size
        )

        // Convert PCM → AAC
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return self.inputBuffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        // Always reset accumulated frames before returning so we don't loop on the same data.
        defer {
            state.inputBufferFrameCount = 0
            inputBuffer.frameLength = 0
        }

        guard status != .error, error == nil else {
            print("❌ AudioEncoder: Conversion failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }

        // Extract AAC data
        guard let packetDescriptions = outputBuffer.packetDescriptions,
              outputBuffer.packetCount > 0 else {
            return nil
        }

        let packetDesc = packetDescriptions[0]
        let aacData = Data(
            bytes: outputBuffer.data.advanced(by: Int(packetDesc.mStartOffset)),
            count: Int(packetDesc.mDataByteSize)
        )

        // Create format description for AAC
        let formatDesc = createAACFormatDescription()

        return EncodedAudioFrame(
            data: aacData,
            pts: timestamp,
            formatDescription: formatDesc
        )
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
