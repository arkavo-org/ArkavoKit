import Foundation
@preconcurrency import AVFoundation
import CoreMedia

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

    /// Creates FLV video tag for H.264 data
    public static func createVideoTag(
        sampleBuffer: CMSampleBuffer,
        timestamp: CMTime,
        isKeyframe: Bool
    ) throws -> Data {
        // Extract H.264 data from sample buffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw FLVError.invalidSampleBuffer
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

        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else {
            throw FLVError.bufferAccessFailed
        }

        let nalData = Data(bytes: pointer, count: length)

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

        // Create FLV tag
        let timestampMs = UInt32(timestamp.seconds * 1000)
        return createTag(
            type: .video,
            data: videoData,
            timestamp: timestampMs
        )
    }

    /// Creates FLV video sequence header (SPS/PPS)
    public static func createVideoSequenceHeader(
        formatDescription: CMFormatDescription,
        timestamp: CMTime
    ) throws -> Data {
        // Extract SPS and PPS from format description
        var parameterSetCount: Int = 0
        var nalUnitHeaderLength: Int32 = 0
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

        guard status == noErr else {
            throw FLVError.formatDescriptionFailed
        }

        // Build AVC decoder configuration record (AVCDecoderConfigurationRecord)
        var avcC = Data()

        avcC.append(0x01)  // configurationVersion
        avcC.append(0x42)  // AVCProfileIndication (baseline)
        avcC.append(0x00)  // profile_compatibility
        avcC.append(0x1E)  // AVCLevelIndication (3.0)
        avcC.append(0xFF)  // lengthSizeMinusOne (4 bytes)

        // SPS
        avcC.append(0xE1)  // numOfSequenceParameterSets (1)
        if let sps = parameterSetPointer {
            let spsSize = UInt16(parameterSetSize)
            avcC.append(contentsOf: spsSize.bigEndianBytes)
            avcC.append(contentsOf: UnsafeBufferPointer(start: sps, count: parameterSetSize))
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

        guard ppsStatus == noErr, let pps = ppsPointer else {
            throw FLVError.formatDescriptionFailed
        }

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

        let timestampMs = UInt32(timestamp.seconds * 1000)
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

    /// Creates FLV audio tag for AAC data
    public static func createAudioTag(
        sampleBuffer: CMSampleBuffer,
        timestamp: CMTime
    ) throws -> Data {
        // Extract AAC data
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw FLVError.invalidSampleBuffer
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

        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else {
            throw FLVError.bufferAccessFailed
        }

        let aacData = Data(bytes: pointer, count: length)

        // Create audio data
        var audioData = Data()

        // Sound format (4 bits) + sound rate (2 bits) + sound size (1 bit) + sound type (1 bit)
        // AAC, 44/48kHz, 16-bit, stereo
        // 0x03 = 44/48 kHz, 0x02 = 16-bit, 0x01 = stereo
        let audioFlags: UInt8 = (AudioFormat.aac.rawValue << 4) | 0x03 | 0x02 | 0x01
        audioData.append(audioFlags)

        // AAC packet type
        audioData.append(AACPacketType.raw.rawValue)

        // AAC audio data
        audioData.append(aacData)

        let timestampMs = UInt32(timestamp.seconds * 1000)
        return createTag(
            type: .audio,
            data: audioData,
            timestamp: timestampMs
        )
    }

    /// Creates FLV audio sequence header (AAC audio specific config)
    public static func createAudioSequenceHeader(
        formatDescription: CMFormatDescription,
        timestamp: CMTime
    ) throws -> Data {
        // Get AAC magic cookie (audio specific config)
        var audioSpecificConfig = Data()
        var cookieSize: Int = 0
        if let cookie = CMAudioFormatDescriptionGetMagicCookie(formatDescription, sizeOut: &cookieSize) {
            audioSpecificConfig = Data(bytes: cookie, count: cookieSize)
        } else {
            // Default AAC-LC, 48kHz, stereo
            // 0x11, 0x90 = AAC-LC (2), 48kHz (3), stereo (2)
            audioSpecificConfig = Data([0x11, 0x90])
        }

        // Create audio data
        var audioData = Data()
        let audioFlags: UInt8 = (AudioFormat.aac.rawValue << 4) | 0x03 | 0x02 | 0x01
        audioData.append(audioFlags)
        audioData.append(AACPacketType.sequenceHeader.rawValue)
        audioData.append(audioSpecificConfig)

        let timestampMs = UInt32(timestamp.seconds * 1000)
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
        let dataSize = UInt32(data.count)
        tag.append(UInt8((dataSize >> 16) & 0xFF))
        tag.append(UInt8((dataSize >> 8) & 0xFF))
        tag.append(UInt8(dataSize & 0xFF))

        // Timestamp (3 bytes lower + 1 byte upper)
        tag.append(UInt8((timestamp >> 16) & 0xFF))
        tag.append(UInt8((timestamp >> 8) & 0xFF))
        tag.append(UInt8(timestamp & 0xFF))
        tag.append(UInt8((timestamp >> 24) & 0xFF))  // Extended timestamp

        // Stream ID (3 bytes, always 0)
        tag.append(contentsOf: [0x00, 0x00, 0x00])

        // Tag data
        tag.append(data)

        // Previous tag size (4 bytes)
        let previousTagSize = UInt32(tag.count)
        tag.append(contentsOf: previousTagSize.bigEndianBytes)

        return tag
    }

    // MARK: - Metadata

    /// Creates FLV metadata tag (onMetaData)
    public static func createMetadata(
        width: Int,
        height: Int,
        framerate: Double,
        videoBitrate: Double,
        audioBitrate: Double
    ) -> Data {
        // Create AMF0 encoded onMetaData script
        let metadata = Data()

        // TODO: This would require full AMF0 encoding implementation
        // For now, return empty - will implement with AMF.swift

        return createTag(
            type: .scriptData,
            data: metadata,
            timestamp: 0
        )
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
