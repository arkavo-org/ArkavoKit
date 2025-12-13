import AVFoundation
import CoreMedia
import Foundation

/// FLV Demuxer for parsing RTMP video/audio payloads
///
/// Extracts H.264 NALUs and AAC frames from FLV tag payloads.
public struct FLVDemuxer: Sendable {
    // MARK: - Types

    public enum DemuxError: Error, LocalizedError {
        case invalidData
        case unsupportedCodec(String)
        case missingSequenceHeader
        case invalidNALU

        public var errorDescription: String? {
            switch self {
            case .invalidData:
                return "Invalid FLV data"
            case let .unsupportedCodec(codec):
                return "Unsupported codec: \(codec)"
            case .missingSequenceHeader:
                return "Missing sequence header"
            case .invalidNALU:
                return "Invalid NALU data"
            }
        }
    }

    /// Parsed video frame
    public struct VideoFrame: Sendable {
        public let nalus: [Data]  // H.264 NALUs without start codes
        public let isKeyframe: Bool
        public let compositionTime: Int32  // CTS offset in ms
        public let pts: CMTime
        public let dts: CMTime
    }

    /// Parsed audio frame
    public struct AudioFrame: Sendable {
        public let data: Data  // Raw AAC frame
        public let pts: CMTime
    }

    /// AVC (H.264) decoder configuration
    public struct AVCDecoderConfig: Sendable {
        public let sps: Data
        public let pps: Data
        public let profileIndication: UInt8
        public let profileCompatibility: UInt8
        public let levelIndication: UInt8
        public let naluLengthSize: UInt8  // Usually 4

        public func createFormatDescription() throws -> CMVideoFormatDescription {
            var formatDescription: CMVideoFormatDescription?

            // Create arrays for parameter sets
            let spsArray = [UInt8](sps)
            let ppsArray = [UInt8](pps)
            let parameterSetSizes: [Int] = [spsArray.count, ppsArray.count]

            // Use nested withUnsafeBufferPointer to ensure pointers remain valid
            let status = spsArray.withUnsafeBufferPointer { spsBuffer in
                ppsArray.withUnsafeBufferPointer { ppsBuffer in
                    // Create array of pointers inside the safe scope
                    var parameterSetPointers: [UnsafePointer<UInt8>] = [
                        spsBuffer.baseAddress!,
                        ppsBuffer.baseAddress!,
                    ]
                    return parameterSetPointers.withUnsafeMutableBufferPointer { pointersBuffer in
                        parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: pointersBuffer.baseAddress!,
                                parameterSetSizes: sizesBuffer.baseAddress!,
                                nalUnitHeaderLength: Int32(naluLengthSize),
                                formatDescriptionOut: &formatDescription
                            )
                        }
                    }
                }
            }

            guard status == noErr, let desc = formatDescription else {
                throw DemuxError.invalidData
            }

            return desc
        }
    }

    /// AAC decoder configuration
    public struct AACDecoderConfig: Sendable {
        public let audioSpecificConfig: Data
        public let sampleRate: Int
        public let channelCount: Int

        public func createFormatDescription() throws -> CMAudioFormatDescription {
            // Parse AudioSpecificConfig
            guard audioSpecificConfig.count >= 2 else {
                throw DemuxError.invalidData
            }

            // Build ASBD
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(sampleRate),
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 1024,
                mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(channelCount),
                mBitsPerChannel: 0,
                mReserved: 0
            )

            var formatDescription: CMAudioFormatDescription?

            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: audioSpecificConfig.count,
                magicCookie: (audioSpecificConfig as NSData).bytes,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )

            guard status == noErr, let desc = formatDescription else {
                throw DemuxError.invalidData
            }

            return desc
        }
    }

    // MARK: - Static Methods

    /// Parse AVC (H.264) sequence header from FLV video tag
    public static func parseAVCSequenceHeader(_ data: Data) throws -> AVCDecoderConfig {
        // FLV video tag format:
        // byte 0: frame type (4 bits) | codec id (4 bits)
        // byte 1: AVC packet type (0 = sequence header)
        // bytes 2-4: composition time (signed 24-bit)
        // bytes 5+: AVCDecoderConfigurationRecord

        guard data.count > 5 else {
            throw DemuxError.invalidData
        }

        let codecId = data[0] & 0x0F
        guard codecId == 7 else {  // AVC
            throw DemuxError.unsupportedCodec("Video codec \(codecId) is not AVC")
        }

        let avcPacketType = data[1]
        guard avcPacketType == 0 else {
            throw DemuxError.invalidData
        }

        // Parse AVCDecoderConfigurationRecord starting at byte 5
        let config = data.subdata(in: 5 ..< data.count)
        guard config.count >= 7 else {
            throw DemuxError.invalidData
        }

        let profileIndication = config[1]
        let profileCompatibility = config[2]
        let levelIndication = config[3]
        let naluLengthSize = (config[4] & 0x03) + 1

        // Parse SPS
        let numSPS = config[5] & 0x1F
        guard numSPS >= 1 else {
            throw DemuxError.invalidData
        }

        var offset = 6
        guard config.count > offset + 2 else {
            throw DemuxError.invalidData
        }

        let spsLength = Int(config[offset]) << 8 | Int(config[offset + 1])
        offset += 2

        guard config.count >= offset + spsLength else {
            throw DemuxError.invalidData
        }

        let sps = config.subdata(in: offset ..< offset + spsLength)
        offset += spsLength

        // Parse PPS
        guard config.count > offset else {
            throw DemuxError.invalidData
        }

        let numPPS = config[offset]
        offset += 1

        guard numPPS >= 1, config.count > offset + 2 else {
            throw DemuxError.invalidData
        }

        let ppsLength = Int(config[offset]) << 8 | Int(config[offset + 1])
        offset += 2

        guard config.count >= offset + ppsLength else {
            throw DemuxError.invalidData
        }

        let pps = config.subdata(in: offset ..< offset + ppsLength)

        return AVCDecoderConfig(
            sps: sps,
            pps: pps,
            profileIndication: profileIndication,
            profileCompatibility: profileCompatibility,
            levelIndication: levelIndication,
            naluLengthSize: naluLengthSize
        )
    }

    /// Parse AAC sequence header from FLV audio tag
    public static func parseAACSequenceHeader(_ data: Data) throws -> AACDecoderConfig {
        // FLV audio tag format:
        // byte 0: sound format (4 bits) | rate (2 bits) | size (1 bit) | type (1 bit)
        // byte 1: AAC packet type (0 = sequence header)
        // bytes 2+: AudioSpecificConfig

        guard data.count >= 4 else {
            throw DemuxError.invalidData
        }

        let soundFormat = (data[0] >> 4) & 0x0F
        guard soundFormat == 10 else {  // AAC
            throw DemuxError.unsupportedCodec("Audio format \(soundFormat) is not AAC")
        }

        let aacPacketType = data[1]
        guard aacPacketType == 0 else {
            throw DemuxError.invalidData
        }

        let audioSpecificConfig = data.subdata(in: 2 ..< data.count)

        // Parse AudioSpecificConfig to get sample rate and channels
        guard audioSpecificConfig.count >= 2 else {
            throw DemuxError.invalidData
        }

        let byte0 = audioSpecificConfig[0]
        let byte1 = audioSpecificConfig[1]

        // audioObjectType = (byte0 >> 3) & 0x1F
        let samplingFrequencyIndex = ((byte0 & 0x07) << 1) | ((byte1 >> 7) & 0x01)
        let channelConfiguration = (byte1 >> 3) & 0x0F

        let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let sampleRate = samplingFrequencyIndex < sampleRates.count ? sampleRates[Int(samplingFrequencyIndex)] : 44100

        return AACDecoderConfig(
            audioSpecificConfig: audioSpecificConfig,
            sampleRate: sampleRate,
            channelCount: Int(channelConfiguration)
        )
    }

    /// Parse AVC (H.264) video frame from FLV video tag
    public static func parseAVCVideoFrame(_ data: Data, naluLengthSize: Int, baseTimestamp: UInt32) throws -> VideoFrame {
        guard data.count > 5 else {
            throw DemuxError.invalidData
        }

        let frameType = (data[0] >> 4) & 0x0F
        var isKeyframe = frameType == 1  // Will also check NAL types below

        let avcPacketType = data[1]
        guard avcPacketType == 1 else {  // NALU
            throw DemuxError.invalidData
        }

        // Composition time offset (signed 24-bit)
        let ct0 = Int32(data[2])
        let ct1 = Int32(data[3])
        let ct2 = Int32(data[4])
        var compositionTime = (ct0 << 16) | (ct1 << 8) | ct2
        // Sign extend if negative
        if compositionTime & 0x0080_0000 != 0 {
            compositionTime |= Int32(bitPattern: 0xFF00_0000)
        }

        // Parse NALUs - FLV header is 5 bytes, NALU data starts at offset 5
        // Note: NTDF decryption is handled by NTDFStreamingSubscriber before this function
        var nalus: [Data] = []
        var offset = 5

        while offset + naluLengthSize <= data.count {
            var naluLength = 0
            for i in 0 ..< naluLengthSize {
                naluLength = (naluLength << 8) | Int(data[offset + i])
            }
            offset += naluLengthSize

            guard offset + naluLength <= data.count else {
                break
            }

            let nalu = data.subdata(in: offset ..< offset + naluLength)
            nalus.append(nalu)
            offset += naluLength
        }

        // Check NAL unit types for keyframe detection (H.264)
        // NAL type 5 = IDR slice (keyframe), NAL type 1 = non-IDR slice
        // This provides more reliable keyframe detection than FLV frameType alone
        for nalu in nalus {
            guard !nalu.isEmpty else { continue }
            let nalType = nalu[0] & 0x1F
            if nalType == 5 {
                // IDR slice found - this is definitely a keyframe
                isKeyframe = true
                break
            }
        }

        // Calculate timestamps
        let dts = CMTime(value: CMTimeValue(baseTimestamp), timescale: 1000)
        let pts = CMTime(value: CMTimeValue(Int64(baseTimestamp) + Int64(compositionTime)), timescale: 1000)

        return VideoFrame(
            nalus: nalus,
            isKeyframe: isKeyframe,
            compositionTime: compositionTime,
            pts: pts,
            dts: dts
        )
    }

    /// Parse AAC audio frame from FLV audio tag
    public static func parseAACAudioFrame(_ data: Data, baseTimestamp: UInt32) throws -> AudioFrame {
        guard data.count > 2 else {
            throw DemuxError.invalidData
        }

        let aacPacketType = data[1]
        guard aacPacketType == 1 else {  // Raw AAC
            throw DemuxError.invalidData
        }

        let aacData = data.subdata(in: 2 ..< data.count)
        let pts = CMTime(value: CMTimeValue(baseTimestamp), timescale: 1000)

        return AudioFrame(data: aacData, pts: pts)
    }

    /// Create CMSampleBuffer from parsed video frame
    public static func createVideoSampleBuffer(
        frame: VideoFrame,
        formatDescription: CMVideoFormatDescription,
        naluLengthSize: Int
    ) throws -> CMSampleBuffer {
        // Combine NALUs with length prefix
        var blockData = Data()
        for nalu in frame.nalus {
            var length = UInt32(nalu.count)
            // Write length in big-endian
            for _ in 0 ..< naluLengthSize {
                let shift = (naluLengthSize - 1) * 8
                blockData.append(UInt8((length >> shift) & 0xFF))
                length <<= 8
            }
            blockData.append(nalu)
        }

        // Create block buffer with copied data (important: data must be retained)
        var blockBuffer: CMBlockBuffer?

        // First create an empty block buffer, then append data (which copies it)
        var status = CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: 0,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let buffer = blockBuffer else {
            throw DemuxError.invalidData
        }

        // Append data to block buffer - this copies the data so it's retained
        status = blockData.withUnsafeBytes { bufferPointer in
            CMBlockBufferAppendMemoryBlock(
                buffer,
                memoryBlock: nil,  // nil = allocate new memory
                length: blockData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: blockData.count,
                flags: 0
            )
        }

        guard status == noErr else {
            throw DemuxError.invalidData
        }

        // Copy the actual data into the block buffer
        status = blockData.withUnsafeBytes { bufferPointer in
            CMBlockBufferReplaceDataBytes(
                with: bufferPointer.baseAddress!,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: blockData.count
            )
        }

        guard status == noErr else {
            throw DemuxError.invalidData
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),  // Assume 30fps
            presentationTimeStamp: frame.pts,
            decodeTimeStamp: frame.dts
        )

        var sampleSize = blockData.count

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sample = sampleBuffer else {
            throw DemuxError.invalidData
        }

        // Set keyframe attachment
        if frame.isKeyframe {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
            if let array = attachments as? [[CFString: Any]], !array.isEmpty {
                var dict = array[0]
                dict[kCMSampleAttachmentKey_NotSync] = false
                // Note: Can't easily modify attachments after creation
            }
        }

        return sample
    }

    /// Create CMSampleBuffer from parsed audio frame
    public static func createAudioSampleBuffer(
        frame: AudioFrame,
        formatDescription: CMAudioFormatDescription,
        sampleRate: Int = 48000
    ) throws -> CMSampleBuffer {
        // Create block buffer with copied data (important: data must be retained)
        var blockBuffer: CMBlockBuffer?
        let blockData = frame.data

        // First create an empty block buffer, then append data (which copies it)
        var status = CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: 0,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let buffer = blockBuffer else {
            throw DemuxError.invalidData
        }

        // Append data to block buffer - this allocates and copies
        status = CMBlockBufferAppendMemoryBlock(
            buffer,
            memoryBlock: nil,  // nil = allocate new memory
            length: blockData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: blockData.count,
            flags: 0
        )

        guard status == noErr else {
            throw DemuxError.invalidData
        }

        // Copy the actual data into the block buffer
        status = blockData.withUnsafeBytes { bufferPointer in
            CMBlockBufferReplaceDataBytes(
                with: bufferPointer.baseAddress!,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: blockData.count
            )
        }

        guard status == noErr else {
            throw DemuxError.invalidData
        }

        // Create sample buffer with correct sample rate
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1024, timescale: Int32(sampleRate)),  // AAC frame duration
            presentationTimeStamp: frame.pts,
            decodeTimeStamp: frame.pts
        )

        var sampleSize = blockData.count

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sample = sampleBuffer else {
            throw DemuxError.invalidData
        }

        return sample
    }
}
