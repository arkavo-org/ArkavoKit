import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import ArkavoMedia

/// FLV (Flash Video) muxer for RTMP streaming
///
/// Converts H.264 video and AAC audio into FLV container format for RTMP transmission.
public struct FLVMuxer: Sendable {

    // MARK: - FLV Header

    /// Creates FLV file header
    /// Format: "FLV" + version(1) + flags(5=audio+video) + header size(9)
    public static func createHeader() -> Data {
        var header = Data()
        header.append(contentsOf: [0x46, 0x4C, 0x56])  // "FLV"
        header.append(0x01)  // Version 1
        header.append(0x05)  // Flags: audio + video
        header.append(contentsOf: [0x00, 0x00, 0x00, 0x09])  // Header size
        header.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // Previous tag size 0
        return header
    }

    // MARK: - Helpers

    /// Safely copies all bytes from a `CMBlockBuffer`, handling non-contiguous buffers.
    private static func copyBlockBufferData(_ dataBuffer: CMBlockBuffer) throws -> Data {
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else {
            return Data()
        }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == kCMBlockBufferNoErr else {
            throw FLVError.bufferAccessFailed
        }
        return data
    }

    /// Safely converts a `CMTime` to FLV timestamp milliseconds without trapping on
    /// invalid, NaN, infinite, negative, or out-of-range values.
    static func timestampMilliseconds(from timestamp: CMTime) -> UInt32 {
        guard timestamp.isNumeric else { return 0 }
        let seconds = timestamp.seconds
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        let ms = seconds * 1000.0
        guard ms.isFinite else { return 0 }
        if ms >= Double(UInt32.max) {
            return UInt32.max
        }
        return UInt32(ms)
    }

    private static func avcLengthSizeMinusOneByte(from nalUnitHeaderLength: Int32) -> UInt8 {
        let validLength = (1...4).contains(nalUnitHeaderLength) ? nalUnitHeaderLength : 4
        return 0xFC | UInt8((validLength - 1) & 0x03)
    }

    // MARK: - Video Tags

    public enum VideoFrameType: UInt8 {
        case keyframe = 1
        case interframe = 2
        case disposableInterframe = 3
    }

    public enum VideoCodec: UInt8 {
        case avc = 7  // H.264
    }

    public enum AVCPacketType: UInt8 {
        case sequenceHeader = 0  // AVC sequence header (SPS/PPS)
        case nalu = 1            // AVC NALU
        case endOfSequence = 2   // End of sequence
    }

    /// Creates video payload for RTMP (without FLV tag wrapper)
    public static func createVideoPayload(
        sampleBuffer: CMSampleBuffer,
        isKeyframe: Bool
    ) throws -> Data {
        // Extract H.264 data from sample buffer (safe for non-contiguous CMBlockBuffers)
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw FLVError.invalidSampleBuffer
        }

        let nalData = try copyBlockBufferData(dataBuffer)

        // Create video data (FLV video tag payload)
        var videoData = Data()

        // Frame type and codec ID (1 byte)
        let frameType: VideoFrameType = isKeyframe ? .keyframe : .interframe
        let videoFlags = (frameType.rawValue << 4) | VideoCodec.avc.rawValue
        videoData.append(videoFlags)

        // AVC packet type (1 byte)
        videoData.append(AVCPacketType.nalu.rawValue)

        // Composition time (3 bytes, always 0 for simple streaming)
        videoData.append(contentsOf: [0x00, 0x00, 0x00])

        // AVC video data
        videoData.append(nalData)

        return videoData
    }

    /// Creates FLV video tag for H.264 data (for FLV files)
    public static func createVideoTag(
        sampleBuffer: CMSampleBuffer,
        timestamp: CMTime,
        isKeyframe: Bool
    ) throws -> Data {
        let videoData = try createVideoPayload(sampleBuffer: sampleBuffer, isKeyframe: isKeyframe)

        // Create FLV tag
        let timestampMs = timestampMilliseconds(from: timestamp)
        return createTag(
            type: .video,
            data: videoData,
            timestamp: timestampMs
        )
    }

    /// Creates video sequence header payload for RTMP (without FLV tag wrapper)
    public static func createVideoSequenceHeaderPayload(
        formatDescription: CMFormatDescription
    ) throws -> Data {
        // Extract SPS and PPS from format description
        var parameterSetCount: Int = 0
        var nalUnitHeaderLength: Int32 = 4
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize: Int = 0

        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )

        guard status == noErr,
              parameterSetCount >= 2,
              let sps = parameterSetPointer,
              parameterSetSize >= 4,
              parameterSetSize <= Int(UInt16.max) else {
            throw FLVError.formatDescriptionFailed
        }

        // PPS
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize: Int = 0
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        guard ppsStatus == noErr,
              let pps = ppsPointer,
              ppsSize > 0,
              ppsSize <= Int(UInt16.max) else {
            throw FLVError.formatDescriptionFailed
        }

        // Build AVC decoder configuration record (AVCDecoderConfigurationRecord)
        var avcC = Data()

        avcC.append(0x01)   // configurationVersion
        avcC.append(sps[1]) // AVCProfileIndication (from SPS)
        avcC.append(sps[2]) // profile_compatibility (from SPS)
        avcC.append(sps[3]) // AVCLevelIndication (from SPS)
        avcC.append(avcLengthSizeMinusOneByte(from: nalUnitHeaderLength))

        // SPS
        avcC.append(0xE1)  // numOfSequenceParameterSets (1)
        let spsSizeU16 = UInt16(parameterSetSize)
        avcC.append(contentsOf: spsSizeU16.bigEndianBytes)
        avcC.append(contentsOf: UnsafeBufferPointer(start: sps, count: parameterSetSize))

        // PPS
        avcC.append(0x01)  // numOfPictureParameterSets (1)
        let ppsLength = UInt16(ppsSize)
        avcC.append(contentsOf: ppsLength.bigEndianBytes)
        avcC.append(contentsOf: UnsafeBufferPointer(start: pps, count: ppsSize))

        // Create video data
        var videoData = Data()
        videoData.append((VideoFrameType.keyframe.rawValue << 4) | VideoCodec.avc.rawValue)
        videoData.append(AVCPacketType.sequenceHeader.rawValue)
        videoData.append(contentsOf: [0x00, 0x00, 0x00])  // Composition time
        videoData.append(avcC)

        return videoData
    }

    /// Creates FLV video sequence header (SPS/PPS) for FLV files
    public static func createVideoSequenceHeader(
        formatDescription: CMFormatDescription,
        timestamp: CMTime
    ) throws -> Data {
        let videoData = try createVideoSequenceHeaderPayload(formatDescription: formatDescription)

        let timestampMs = timestampMilliseconds(from: timestamp)
        return createTag(
            type: .video,
            data: videoData,
            timestamp: timestampMs
        )
    }

    // MARK: - Audio Tags

    public enum AudioFormat: UInt8 {
        case aac = 10
    }

    public enum AACPacketType: UInt8 {
        case sequenceHeader = 0
        case raw = 1
    }

    // MARK: - Audio Constants

    /// Standard AAC audio format flags: AAC codec, 44/48kHz, 16-bit, stereo
    /// Binary: 10101111 = bits[7:4]=1010 (AAC), bits[3:2]=11 (44/48kHz), bit[1]=1 (16-bit), bit[0]=1 (stereo)
    private static let AAC_AUDIO_FLAGS: UInt8 = 0xAF

    /// Fallback AudioSpecificConfig when magic cookie unavailable or invalid
    /// 0x11 0x90 = AAC-LC, 48kHz, stereo
    private static let FALLBACK_AUDIO_SPECIFIC_CONFIG = Data([0x11, 0x90])

    /// Creates audio payload for RTMP (without FLV tag wrapper)
    public static func createAudioPayload(
        sampleBuffer: CMSampleBuffer
    ) throws -> Data {
        // Extract AAC data (safe for non-contiguous CMBlockBuffers)
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw FLVError.invalidSampleBuffer
        }

        let aacData = try copyBlockBufferData(dataBuffer)

        // Create audio data
        var audioData = Data()

        // Sound format (4 bits) + sound rate (2 bits) + sound size (1 bit) + sound type (1 bit)
        // AAC, 44/48kHz, 16-bit, stereo
        // OBS uses 0xAF: bits 7-4=1010 (AAC), bits 3-2=11 (44/48kHz), bit 1=1 (16-bit), bit 0=1 (stereo)
        let soundFormat: UInt8 = AudioFormat.aac.rawValue  // 10
        let soundRate: UInt8 = 3  // 44/48 kHz
        let soundSize: UInt8 = 1  // 16-bit
        let soundType: UInt8 = 1  // stereo
        let audioFlags: UInt8 = (soundFormat << 4) | (soundRate << 2) | (soundSize << 1) | soundType
        audioData.append(audioFlags)  // Should be 0xAF

        // AAC packet type
        audioData.append(AACPacketType.raw.rawValue)

        // AAC audio data
        audioData.append(aacData)

        return audioData
    }

    /// Creates FLV audio tag for AAC data (for FLV files)
    public static func createAudioTag(
        sampleBuffer: CMSampleBuffer,
        timestamp: CMTime
    ) throws -> Data {
        let audioData = try createAudioPayload(sampleBuffer: sampleBuffer)

        let timestampMs = timestampMilliseconds(from: timestamp)
        return createTag(
            type: .audio,
            data: audioData,
            timestamp: timestampMs
        )
    }

    /// Helper function to manually construct AudioSpecificConfig for AAC
    private static func constructAudioSpecificConfig(
        objectType: UInt8,  // 2 for AAC-LC
        sampleRate: Double,
        channels: UInt32
    ) -> Data {
        // Map sample rate to index per ISO 14496-3 Table 1.18
        let roundedSampleRate: Int
        if sampleRate.isFinite && sampleRate > 0 && sampleRate <= Double(Int.max) {
            roundedSampleRate = Int(sampleRate)
        } else {
            roundedSampleRate = 48000
        }

        let sampleRateIndex: UInt8
        switch roundedSampleRate {
        case 96000: sampleRateIndex = 0
        case 88200: sampleRateIndex = 1
        case 64000: sampleRateIndex = 2
        case 48000: sampleRateIndex = 3
        case 44100: sampleRateIndex = 4
        case 32000: sampleRateIndex = 5
        case 24000: sampleRateIndex = 6
        case 22050: sampleRateIndex = 7
        case 16000: sampleRateIndex = 8
        case 12000: sampleRateIndex = 9
        case 11025: sampleRateIndex = 10
        case 8000: sampleRateIndex = 11
        case 7350: sampleRateIndex = 12
        default:
            print("⚠️ Unsupported sample rate \(sampleRate), defaulting to 48kHz (index 3)")
            sampleRateIndex = 3
        }

        // Map channel count to config (1=mono, 2=stereo, etc.)
        let channelConfig = UInt8(min(channels, 7))

        // Construct 2-byte AudioSpecificConfig
        // Byte 1: OOOOOSSS (5 bits object type + 3 bits sample rate upper)
        let byte1 = (objectType << 3) | ((sampleRateIndex >> 1) & 0x07)

        // Byte 2: SCCCCFDE (1 bit sample rate lower + 4 bits channel + 3 bits flags)
        let byte2 = ((sampleRateIndex & 0x01) << 7) | (channelConfig << 3)

        print("🎵 Constructed AudioSpecificConfig: objectType=\(objectType), srIndex=\(sampleRateIndex), channels=\(channelConfig)")
        print("   Byte 1: 0x\(String(format: "%02x", byte1)), Byte 2: 0x\(String(format: "%02x", byte2))")

        return Data([byte1, byte2])
    }

    /// Creates audio sequence header payload for RTMP (without FLV tag wrapper)
    public static func createAudioSequenceHeaderPayload(
        formatDescription: CMFormatDescription
    ) -> Data {
        var audioSpecificConfig = Data()
        var cookieSize: Int = 0

        // Try to get magic cookie from format description
        if let cookie = CMAudioFormatDescriptionGetMagicCookie(formatDescription, sizeOut: &cookieSize),
           cookieSize > 0 {
            audioSpecificConfig = Data(bytes: cookie, count: cookieSize)
            print("🎵 Got AAC magic cookie: \(cookieSize) bytes: \(audioSpecificConfig.map { String(format: "%02x", $0) }.joined(separator: " "))")

            // VALIDATE the AudioSpecificConfig
            if cookieSize >= 2 {
                let byte1 = audioSpecificConfig[0]
                let byte2 = audioSpecificConfig[1]

                // Decode object type (bits 7-3 of byte 1)
                let objectType = (byte1 >> 3) & 0x1F

                // Decode sample rate index (bits 2-0 of byte1 + bit 7 of byte2)
                let srIndex = ((byte1 & 0x07) << 1) | ((byte2 >> 7) & 0x01)

                // Decode channel config (bits 6-3 of byte2)
                let channelConfig = (byte2 >> 3) & 0x0F

                print("🎵 Decoded AudioSpecificConfig: objectType=\(objectType) (2=AAC-LC), srIndex=\(srIndex) (3=48kHz,4=44.1kHz), channels=\(channelConfig) (2=stereo)")

                // Verify it's valid AAC-LC for RTMP streaming
                if objectType != 2 {
                    print("⚠️ WARNING: Object type is \(objectType), not 2 (AAC-LC)! This may cause decoder errors.")
                }
                if srIndex != 3 && srIndex != 4 {
                    print("⚠️ WARNING: Sample rate index is \(srIndex), not 3 (48kHz) or 4 (44.1kHz)! This may cause decoder errors.")
                }
                if channelConfig != 2 {
                    print("⚠️ WARNING: Channel config is \(channelConfig), not 2 (stereo)! This may cause decoder errors.")
                }

                // If any validation failed, reconstruct manually
                if objectType != 2 || (srIndex != 3 && srIndex != 4) || channelConfig != 2 {
                    print("❌ Invalid AudioSpecificConfig from encoder, constructing manually")
                    // Get correct parameters from ASBD
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
                        audioSpecificConfig = constructAudioSpecificConfig(
                            objectType: 2,  // Force AAC-LC
                            sampleRate: asbd.mSampleRate,
                            channels: asbd.mChannelsPerFrame
                        )
                    } else {
                        // Ultimate fallback: AAC-LC, 48kHz, stereo
                        audioSpecificConfig = FALLBACK_AUDIO_SPECIFIC_CONFIG
                    }
                } else if cookieSize > 2 {
                    // Magic cookie is longer than 2 bytes - may contain PCE or other extensions
                    // Truncate to basic AudioSpecificConfig to avoid corruption
                    print("⚠️ Magic cookie is \(cookieSize) bytes (expected 2). Truncating to basic AudioSpecificConfig.")
                    audioSpecificConfig = Data([byte1, byte2])
                }
            } else {
                print("❌ Magic cookie too short (\(cookieSize) bytes), constructing manually")
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
                    audioSpecificConfig = constructAudioSpecificConfig(
                        objectType: 2,
                        sampleRate: asbd.mSampleRate,
                        channels: asbd.mChannelsPerFrame
                    )
                } else {
                    audioSpecificConfig = FALLBACK_AUDIO_SPECIFIC_CONFIG
                }
            }
        } else {
            // No magic cookie - construct manually from ASBD
            print("⚠️ No magic cookie in format description, constructing AudioSpecificConfig manually")

            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
                let sampleRate = asbd.mSampleRate
                let channels = asbd.mChannelsPerFrame

                print("🎵 ASBD: sampleRate=\(sampleRate), channels=\(channels), formatID=\(asbd.mFormatID)")

                audioSpecificConfig = constructAudioSpecificConfig(
                    objectType: 2,  // AAC-LC
                    sampleRate: sampleRate,
                    channels: channels
                )
            } else {
                // Ultimate fallback: AAC-LC, 48kHz, stereo
                print("⚠️ No ASBD available, using fallback AudioSpecificConfig: 0x11 0x90")
                audioSpecificConfig = FALLBACK_AUDIO_SPECIFIC_CONFIG
            }
        }

        print("✅ Final AudioSpecificConfig: \(audioSpecificConfig.map { String(format: "%02x", $0) }.joined(separator: " "))")

        // Create audio data
        var audioData = Data()
        // OBS uses 0xAF for AAC audio format byte
        let soundFormat: UInt8 = AudioFormat.aac.rawValue  // 10
        let soundRate: UInt8 = 3  // 44/48 kHz
        let soundSize: UInt8 = 1  // 16-bit
        let soundType: UInt8 = 1  // stereo
        let audioFlags: UInt8 = (soundFormat << 4) | (soundRate << 2) | (soundSize << 1) | soundType
        audioData.append(audioFlags)  // Should be 0xAF
        audioData.append(AACPacketType.sequenceHeader.rawValue)
        audioData.append(audioSpecificConfig)

        return audioData
    }

    /// Creates FLV audio sequence header (AAC audio specific config) for FLV files
    public static func createAudioSequenceHeader(
        formatDescription: CMFormatDescription,
        timestamp: CMTime
    ) -> Data {
        let audioData = createAudioSequenceHeaderPayload(formatDescription: formatDescription)

        let timestampMs = timestampMilliseconds(from: timestamp)
        return createTag(
            type: .audio,
            data: audioData,
            timestamp: timestampMs
        )
    }

    // MARK: - Tag Creation

    public enum TagType: UInt8 {
        case audio = 8
        case video = 9
        case scriptData = 18
    }

    /// Creates FLV tag with header and data
    private static func createTag(type: TagType, data: Data, timestamp: UInt32) -> Data {
        var tag = Data()

        // Tag type (1 byte)
        tag.append(type.rawValue)

        // Data size (3 bytes, big endian)
        let dataSize = UInt32(clamping: data.count)
        tag.append(UInt8((dataSize >> 16) & 0xFF))
        tag.append(UInt8((dataSize >> 8) & 0xFF))
        tag.append(UInt8(dataSize & 0xFF))

        // Timestamp (3 bytes lower + 1 byte upper)
        tag.append(UInt8((timestamp >> 16) & 0xFF))
        tag.append(UInt8((timestamp >> 8) & 0xFF))
        tag.append(UInt8(timestamp & 0xFF))
        tag.append(UInt8((timestamp >> 24) & 0x7F))  // Extended timestamp (bit 7 must be 0)

        // Stream ID (3 bytes, always 0)
        tag.append(contentsOf: [0x00, 0x00, 0x00])

        // Tag data
        tag.append(data)

        // Previous tag size (4 bytes)
        let previousTagSize = UInt32(clamping: tag.count)
        tag.append(contentsOf: previousTagSize.bigEndianBytes)

        return tag
    }

    // MARK: - Metadata

    /// Creates FLV metadata tag (onMetaData)
    /// - Parameters:
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    ///   - framerate: Video framerate (fps)
    ///   - videoBitrate: Video bitrate in bits/sec
    ///   - audioBitrate: Audio bitrate in bits/sec
    ///   - customFields: Optional custom string fields (e.g., ntdf_header for NanoTDF encryption)
    public static func createMetadata(
        width: Int,
        height: Int,
        framerate: Double,
        videoBitrate: Double,
        audioBitrate: Double,
        customFields: [String: String]? = nil
    ) -> Data {
        // Create AMF0 encoded onMetaData script
        // Format: @setDataFrame string + onMetaData string + ECMA array with properties
        var metadata = Data()

        // String marker (0x02) + UTF-8 byte length + "@setDataFrame"
        metadata.append(AMF0.encodeString("@setDataFrame"))

        // String marker (0x02) + UTF-8 byte length + "onMetaData"
        metadata.append(AMF0.encodeString("onMetaData"))

        // ECMA Array marker (0x08) + approximate count
        let basePropertyCount: UInt32 = 11  // 10 standard + encoder
        let customFieldCount = UInt32(clamping: customFields?.count ?? 0)
        metadata.append(0x08)  // AMF0 ECMA Array marker
        metadata.append(contentsOf: (basePropertyCount &+ customFieldCount).bigEndianBytes)  // Property count

        // Helpers using UTF-8 byte lengths (not String.count)
        func appendPropertyName(_ name: String) {
            let keyBytes = AMF0.truncateUTF8(name, maxBytes: Int(UInt16.max))
            metadata.append(contentsOf: UInt16(keyBytes.count).bigEndianBytes)
            metadata.append(keyBytes)
        }

        func addNumberProperty(name: String, value: Double) {
            appendPropertyName(name)
            metadata.append(0x00)  // AMF0 Number marker
            metadata.append(contentsOf: value.bitPattern.bigEndianBytes)
        }

        func addStringProperty(name: String, value: String) {
            appendPropertyName(name)
            metadata.append(AMF0.encodeString(value))
        }

        func addBooleanProperty(name: String, value: Bool) {
            appendPropertyName(name)
            metadata.append(0x01)  // AMF0 Boolean marker
            metadata.append(value ? 0x01 : 0x00)
        }

        // Add standard metadata properties
        addNumberProperty(name: "width", value: Double(width))
        addNumberProperty(name: "height", value: Double(height))
        addNumberProperty(name: "framerate", value: framerate)
        addNumberProperty(name: "videodatarate", value: videoBitrate / 1000.0)  // kbps
        addNumberProperty(name: "audiodatarate", value: audioBitrate / 1000.0)  // kbps
        addNumberProperty(name: "audiosamplerate", value: 48000.0)
        addNumberProperty(name: "audiosamplesize", value: 16.0)
        addBooleanProperty(name: "stereo", value: true)
        addStringProperty(name: "videocodecid", value: "avc1")  // H.264
        addStringProperty(name: "audiocodecid", value: "mp4a")  // AAC
        addStringProperty(name: "encoder", value: "Arkavo Creator")

        // Add custom fields (e.g., ntdf_header for NanoTDF encryption)
        if let customFields {
            for (key, value) in customFields {
                print("📤 [FLVMuxer] Adding custom field: \(key) = \(value.prefix(50))...")
                addStringProperty(name: key, value: value)
            }
        }

        // Object end marker (0x00 0x00 0x09)
        metadata.append(contentsOf: [0x00, 0x00, 0x09])

        return metadata  // Return raw AMF0 data, not wrapped in FLV tag
    }

    // MARK: - Simplified API for EncodedFrame

    /// Create video payload from EncodedVideoFrame
    public static func createVideoPayload(from frame: EncodedVideoFrame) -> Data {
        var payload = Data()

        // Frame type and codec ID
        let frameType: UInt8 = frame.isKeyframe ? 0x10 : 0x20  // 1=keyframe, 2=inter
        let codecID: UInt8 = 0x07  // AVC (H.264)
        payload.append(frameType | codecID)

        // AVC packet type: 1 = NALU
        payload.append(0x01)

        // Composition time: 0 (no B-frames)
        payload.append(contentsOf: [0x00, 0x00, 0x00])

        // Append H.264 data
        payload.append(frame.data)

        return payload
    }

    /// Create audio payload from EncodedAudioFrame
    public static func createAudioPayload(from frame: EncodedAudioFrame) -> Data {
        var payload = Data()

        // Sound format (4 bits) | sample rate (2 bits) | sample size (1 bit) | sound type (1 bit)
        // AAC = 10 (0xA), 44kHz+ = 3, 16-bit = 1, stereo = 1
        payload.append(AAC_AUDIO_FLAGS)

        // AAC packet type: 1 = AAC raw
        payload.append(0x01)

        // Append AAC data
        payload.append(frame.data)

        return payload
    }

    /// Create video sequence header from format description
    public static func createVideoSequenceHeader(from formatDesc: CMVideoFormatDescription) throws -> Data {
        // Delegate to the validated AVCDecoderConfigurationRecord builder so both paths
        // check OSStatus, spsSize >= 4, and honor actual nalUnitHeaderLength.
        try createVideoSequenceHeaderPayload(formatDescription: formatDesc)
    }

    /// Create audio sequence header from AudioSpecificConfig
    public static func createAudioSequenceHeader(asc: Data) -> Data {
        var payload = Data()

        // Sound format
        payload.append(AAC_AUDIO_FLAGS)

        // AAC packet type: 0 = sequence header
        payload.append(0x00)

        // AudioSpecificConfig
        payload.append(asc)

        return payload
    }
}

// MARK: - Errors

public enum FLVError: Error, LocalizedError {
    case invalidSampleBuffer
    case bufferAccessFailed
    case formatDescriptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSampleBuffer:
            return "Invalid sample buffer"
        case .bufferAccessFailed:
            return "Failed to access buffer data"
        case .formatDescriptionFailed:
            return "Failed to get format description"
        }
    }
}
