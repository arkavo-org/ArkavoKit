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
        /// Interleaved PCM not yet encoded; always less than one AAC packet after a feed.
        var pending: [Int16] = []
        /// Timestamp for the next AAC packet out. Packets advance it by exactly 1024 frames,
        /// so the stream's audio clock counts samples rather than following feed timing.
        var nextOutputPTS: CMTime?
        /// Where the next fed buffer should start if the source is continuous.
        var expectedInputPTS: CMTime?
        var onFrame: (@Sendable (EncodedAudioFrame) -> Void)?
    }

    private let state = Mutex(State())

    // Set in init, immutable thereafter — safe to read without locking.
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let aacFormat: AVAudioFormat
    private let inputBuffer: AVAudioPCMBuffer

    private let targetFrameCount: AVAudioFrameCount = 1024  // AAC frame size
    /// A jump in input timestamps larger than this is a pause in the source, not jitter.
    private let maxContinuityGap: Double = 0.1
    private var aacFormatDescription: CMAudioFormatDescription? { createAACFormatDescription() }
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
    /// Buffers of any length are accepted: every frame is kept and encoded, in 1024-frame packets.
    /// - Parameters:
    ///   - sampleBuffer: PCM audio sample buffer
    public func feed(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            print("❌ AudioEncoder: No data buffer")
            return
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        let bytesPerFrame = Int(pcmFormat.streamDescription.pointee.mBytesPerFrame)
        guard length >= bytesPerFrame else { return }
        var samples = [Int16](repeating: 0, count: length / MemoryLayout<Int16>.size)
        let status = samples.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else {
            print("❌ AudioEncoder: Failed to copy PCM data (\(status))")
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frameCount = length / bytesPerFrame

        let frames: [EncodedAudioFrame] = state.withLock { state in
            self.append(state: &state, samples: samples, frameCount: frameCount, timestamp: timestamp)
        }
        guard !frames.isEmpty, let cb = state.withLock({ $0.onFrame }) else { return }
        for frame in frames { cb(frame) }
    }

    // MARK: - Private Methods

    /// Queue PCM and encode every whole 1024-frame packet it completes, keeping the remainder
    /// for the next feed. Caller must hold the state lock.
    private func append(
        state: inout State,
        samples: [Int16],
        frameCount: Int,
        timestamp: CMTime
    ) -> [EncodedAudioFrame] {
        if state.nextOutputPTS == nil {
            state.nextOutputPTS = timestamp
        } else if timestamp.isNumeric, let expected = state.expectedInputPTS, expected.isNumeric {
            // A source that paused leaves a gap in real time: move the audio clock across it
            // so audio stays level with video. Overlaps are ignored to keep timestamps rising.
            let gap = timestamp - expected
            if gap.seconds > maxContinuityGap, let next = state.nextOutputPTS {
                state.nextOutputPTS = next + gap
            }
        }
        if timestamp.isNumeric {
            state.expectedInputPTS = timestamp + CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(sampleRate))
        }

        state.pending.append(contentsOf: samples)

        let samplesPerPacket = Int(targetFrameCount) * Int(channelCount)
        var frames: [EncodedAudioFrame] = []
        while state.pending.count >= samplesPerPacket {
            if let aac = encodePacket(state.pending.prefix(samplesPerPacket)), let pts = state.nextOutputPTS {
                frames.append(EncodedAudioFrame(data: aac, pts: pts, formatDescription: aacFormatDescription))
                state.nextOutputPTS = pts + CMTime(value: CMTimeValue(targetFrameCount), timescale: CMTimeScale(sampleRate))
            }
            state.pending.removeFirst(samplesPerPacket)
        }
        return frames
    }

    /// Encode exactly one packet's worth of PCM. Returns nil while the encoder is still
    /// filling its look-ahead. Caller must hold the state lock.
    private func encodePacket(_ samples: ArraySlice<Int16>) -> Data? {
        let channelData = inputBuffer.int16ChannelData!
        samples.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress!, count: src.count)
        }
        inputBuffer.frameLength = targetFrameCount

        let outputBuffer = AVAudioCompressedBuffer(
            format: aacFormat,
            packetCapacity: 1,
            maximumPacketSize: 2048  // Max AAC frame size
        )

        // Hand the packet over once; answering .haveData again would encode it twice.
        nonisolated(unsafe) var supplied = false
        let inputBuffer = self.inputBuffer
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { @Sendable _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil else {
            print("❌ AudioEncoder: Conversion failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        guard let packetDescriptions = outputBuffer.packetDescriptions, outputBuffer.packetCount > 0 else {
            return nil
        }
        let packetDesc = packetDescriptions[0]
        return Data(
            bytes: outputBuffer.data.advanced(by: Int(packetDesc.mStartOffset)),
            count: Int(packetDesc.mDataByteSize)
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
