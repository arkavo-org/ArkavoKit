import AVFoundation
import CoreMedia
import AudioToolbox
import Synchronization

/// Hardware-accelerated AAC audio encoder for streaming
/// Buffers incoming PCM samples and outputs AAC frames.
///
/// Thread safety: all `feed(...)` calls and `onFrame` access are serialized through
/// an internal Mutex. The PCM queue and the sample-count clock assume one audio stream on
/// one clock: feed one producer at a time (the recorder's silence fallback only fills gaps
/// in the real audio), or two producers will interleave their samples.
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
    private let aacFormatDescription: CMAudioFormatDescription?
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
        self.aacFormatDescription = Self.makeAACFormatDescription(aacFormat)

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

        // Whole frames only: a trailing partial frame would overrun the copy or shift the
        // channels for the rest of the stream.
        let bytesPerFrame = Int(pcmFormat.streamDescription.pointee.mBytesPerFrame)
        let frameCount = CMBlockBufferGetDataLength(dataBuffer) / bytesPerFrame
        guard frameCount > 0 else { return }
        var samples = [Int16](repeating: 0, count: frameCount * Int(channelCount))
        let status = samples.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: frameCount * bytesPerFrame, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else {
            print("❌ AudioEncoder: Failed to copy PCM data (\(status))")
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

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
        let tick = CMTimeScale(sampleRate)
        let packetDuration = CMTime(value: CMTimeValue(targetFrameCount), timescale: tick)
        if let next = state.nextOutputPTS {
            // Where this buffer should start if nothing was lost: the output clock plus what is
            // still queued. Audio a source dropped or paused over puts the input ahead of that;
            // past the threshold the clock jumps across the difference, so small losses cannot
            // add up into lip-sync drift. Input behind the clock is ignored to keep timestamps
            // rising. The encoder's look-ahead (a packet or two) stays inside the threshold.
            if timestamp.isNumeric {
                let queued = CMTime(value: CMTimeValue(state.pending.count / Int(channelCount)), timescale: tick)
                let drift = timestamp - (next + queued)
                if drift.seconds > maxContinuityGap {
                    state.nextOutputPTS = next + drift
                }
            }
        } else {
            state.nextOutputPTS = timestamp
        }

        state.pending.append(contentsOf: samples)

        let samplesPerPacket = Int(targetFrameCount) * Int(channelCount)
        var frames: [EncodedAudioFrame] = []
        while state.pending.count >= samplesPerPacket, let pts = state.nextOutputPTS {
            switch encodePacket(state.pending.prefix(samplesPerPacket)) {
            case .packet(let aac):
                frames.append(EncodedAudioFrame(data: aac, pts: pts, formatDescription: aacFormatDescription))
                state.nextOutputPTS = pts + packetDuration
            case .failed:
                // The PCM is gone either way; keep the clock on it.
                state.nextOutputPTS = pts + packetDuration
            case .filling:
                break
            }
            state.pending.removeFirst(samplesPerPacket)
        }
        return frames
    }

    private enum PacketResult {
        case packet(Data)
        /// The encoder took the PCM into its look-ahead and has no packet yet.
        case filling
        case failed
    }

    /// Encode exactly one packet's worth of PCM. Caller must hold the state lock.
    private func encodePacket(_ samples: ArraySlice<Int16>) -> PacketResult {
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
        // The converter calls the block synchronously, inside `convert`.
        nonisolated(unsafe) let inputBuffer = self.inputBuffer
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
            return .failed
        }
        guard let packetDescriptions = outputBuffer.packetDescriptions, outputBuffer.packetCount > 0 else {
            return .filling
        }
        let packetDesc = packetDescriptions[0]
        return .packet(Data(
            bytes: outputBuffer.data.advanced(by: Int(packetDesc.mStartOffset)),
            count: Int(packetDesc.mDataByteSize)
        ))
    }

    private static func makeAACFormatDescription(_ aacFormat: AVAudioFormat) -> CMAudioFormatDescription? {
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
