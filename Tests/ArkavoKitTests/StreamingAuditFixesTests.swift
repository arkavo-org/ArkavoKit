import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import OpenTDFKit
import Synchronization
import XCTest
@testable import ArkavoMedia
@testable import ArkavoStreaming

final class StreamingAuditFixesTests: XCTestCase {

    // MARK: - AMF0 Security, Bounds, Recursion, Slices & Extended Markers

    func testAMF0StrictArrayRejectsMaliciousHugeCountWithoutOOM() {
        // 0x0A = strictArray marker, 0xFF FF FF FF = 4,294,967,295 elements with 0 remaining bytes
        let crafted = Data([0x0A, 0xFF, 0xFF, 0xFF, 0xFF])
        var parser = AMF0Parser(data: crafted)

        XCTAssertThrowsError(try parser.readValue()) { error in
            guard case AMF0Parser.ParseError.insufficientData = error else {
                XCTFail("Expected insufficientData, got \(error)")
                return
            }
        }
    }

    func testAMF0RecursionDepthLimitPreventsStackOverflow() {
        // Nest 40 strict arrays of length 1 (exceeds AMF0Parser.maxDepth == 32)
        var crafted = Data()
        for _ in 0 ..< 40 {
            crafted.append(contentsOf: [0x0A, 0x00, 0x00, 0x00, 0x01])
        }
        crafted.append(0x05)  // inner null

        var parser = AMF0Parser(data: crafted)
        XCTAssertThrowsError(try parser.readValue()) { error in
            guard case AMF0Parser.ParseError.maxDepthExceeded = error else {
                XCTFail("Expected maxDepthExceeded, got \(error)")
                return
            }
        }
    }

    func testAMF0ParserHandlesNonZeroStartIndexDataSlice() throws {
        // Prefix garbage bytes so the slice has startIndex == 4
        var full = Data([0xDE, 0xAD, 0xBE, 0xEF])
        full.append(AMF0.encodeString("slice-ok"))
        let slice = full.dropFirst(4)
        XCTAssertEqual(slice.startIndex, 4)

        var parser = AMF0Parser(data: slice)
        let value = try parser.readValue()
        XCTAssertEqual(value, .string("slice-ok"))
    }

    func testAMF0LongStringEncodeAndDecodeRoundTrip() throws {
        // Exceeds UInt16.max (65,535 bytes) -> must encode as 0x0C longString without trapping
        let big = String(repeating: "A", count: 70_000)
        let encoded = AMF0.encodeString(big)
        XCTAssertEqual(encoded.first, AMF0.DataType.longString.rawValue)

        var parser = AMF0Parser(data: encoded)
        let decoded = try parser.readValue()
        XCTAssertEqual(decoded, .string(big))
    }

    func testAMF0SupportsDateReferenceXMLAndTypedObjectMarkers() throws {
        var payload = Data()
        // Date (0x0B): 1000.0 ms + 2-byte timezone (0x0000)
        payload.append(0x0B)
        var msBits = (1000.0).bitPattern.bigEndian
        payload.append(Data(bytes: &msBits, count: 8))
        payload.append(contentsOf: [0x00, 0x00])

        // Reference (0x07): index 3
        payload.append(contentsOf: [0x07, 0x00, 0x03])

        // XML Document (0x0F): "<a/>"
        let xml = Data("<a/>".utf8)
        payload.append(0x0F)
        var xmlLen = UInt32(xml.count).bigEndian
        payload.append(Data(bytes: &xmlLen, count: 4))
        payload.append(xml)

        // Typed Object (0x10): class "Foo", { "k": true }
        payload.append(0x10)
        payload.append(contentsOf: [0x00, 0x03])
        payload.append(Data("Foo".utf8))
        payload.append(contentsOf: [0x00, 0x01])
        payload.append(Data("k".utf8))
        payload.append(contentsOf: [0x01, 0x01])
        payload.append(contentsOf: [0x00, 0x00, 0x09])

        var parser = AMF0Parser(data: payload)
        let values = try parser.readAllValues()
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values[0], .date(1000.0))
        XCTAssertEqual(values[1], .reference(3))
        XCTAssertEqual(values[2], .string("<a/>"))
        XCTAssertEqual(values[3], .object(["k": .boolean(true)]))
    }

    func testAMF0EncodeObjectHandlesOversizedKeyWithoutTrapping() {
        let hugeKey = String(repeating: "k", count: 70_000)
        let encoded = AMF0.encodeObject([hugeKey: .boolean(true)])
        XCTAssertGreaterThan(encoded.count, 65_535)
    }

    // MARK: - Z85 Overflow, Slices & NTDFTokenPayload Safety

    func testZ85DecodeReturnsNilOnUInt32OverflowInsteadOfTrapping() {
        // "#####" represents 84*(85^4+85^3+85^2+85+1) = 4,437,053,124 > UInt32.max
        XCTAssertNil(Z85.decode("#####"))
        // "%nSc0" is exact UInt32.max (0xFFFFFFFF)
        XCTAssertEqual(Z85.decode("%nSc0"), Data([0xFF, 0xFF, 0xFF, 0xFF]))
    }

    func testZ85EncodeHandlesDataSliceWithNonZeroStartIndex() {
        let full = Data([0xAA, 0xBB, 0x86, 0x4F, 0xD2, 0x6F, 0xB5, 0x59, 0xF7, 0x5B])
        let slice = full.dropFirst(2)
        XCTAssertEqual(slice.startIndex, 2)

        let encoded = Z85.encode(slice)
        XCTAssertEqual(encoded, "HelloWorld")
        XCTAssertEqual(Z85.decode(encoded), Data(slice))
    }

    func testZ85EncodeExactEnforcesFourByteAlignment() {
        XCTAssertNil(Z85.encodeExact(Data([0x01, 0x02, 0x03])))
        let aligned = Data([0x86, 0x4F, 0xD2, 0x6F])
        let encoded = Z85.encodeExact(aligned)
        XCTAssertNotNil(encoded)
        XCTAssertEqual(encoded.flatMap { Z85.decode($0) }, aligned)
    }

    func testNTDFTokenPayloadHandlesOversizedFieldsSafely() {
        let oversized = NTDFTokenPayload(
            subId: UUID(),
            flags: [.profile],
            scopes: [String(repeating: "s", count: 300)],
            iat: 100,
            exp: 200,
            aud: "https://kas.example.com",
            deviceId: String(repeating: "d", count: 300)
        )
        // Non-throwing toBytes() must clamp safely without trapping
        XCTAssertFalse(oversized.toBytes().isEmpty)
        // Checked variant must reject oversized fields cleanly
        XCTAssertThrowsError(try oversized.toBytesChecked())
    }

    // MARK: - FLV Muxer & Demuxer Fixes

    func testFLVMuxerCopiesNonContiguousCMBlockBufferCompletely() throws {
        let part1 = Data([0x00, 0x00, 0x00, 0x04, 0x65, 0x11, 0x22, 0x33])
        let part2 = Data([0x44, 0x55, 0x66, 0x77, 0x88, 0x99])

        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault, capacity: 2, flags: 0, blockBufferOut: &blockBuffer),
            kCMBlockBufferNoErr
        )
        let nonContiguous = try XCTUnwrap(blockBuffer)

        for chunk in [part1, part2] {
            var subBlock: CMBlockBuffer?
            XCTAssertEqual(
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: nil,
                    blockLength: chunk.count,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: chunk.count,
                    flags: 0,
                    blockBufferOut: &subBlock
                ),
                kCMBlockBufferNoErr
            )
            let segment = try XCTUnwrap(subBlock)
            let replaceStatus = chunk.withUnsafeBytes { raw -> OSStatus in
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!,
                    blockBuffer: segment,
                    offsetIntoDestination: 0,
                    dataLength: chunk.count
                )
            }
            XCTAssertEqual(replaceStatus, kCMBlockBufferNoErr)
            XCTAssertEqual(
                CMBlockBufferAppendBufferReference(
                    nonContiguous,
                    targetBBuf: segment,
                    offsetToData: 0,
                    dataLength: chunk.count,
                    flags: 0
                ),
                kCMBlockBufferNoErr
            )
        }

        XCTAssertFalse(CMBlockBufferIsRangeContiguous(nonContiguous, atOffset: 0, length: part1.count + part2.count))

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = part1.count + part2.count
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: nonContiguous,
                formatDescription: nil,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        let sample = try XCTUnwrap(sampleBuffer)

        let videoPayload = try FLVMuxer.createVideoPayload(sampleBuffer: sample, isKeyframe: true)
        XCTAssertEqual(videoPayload.dropFirst(5), part1 + part2)

        let audioPayload = try FLVMuxer.createAudioPayload(sampleBuffer: sample)
        XCTAssertEqual(audioPayload.dropFirst(2), part1 + part2)
    }

    func testFLVDemuxerParsesMultiSPSAndSliceAndSetsNotSyncAttachment() throws {
        // Valid H.264 High-profile SPS & PPS parameter sets accepted by CoreMedia
        let sps1 = Data([
            0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0x50,
            0x05, 0xBB, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00,
            0x10, 0x00, 0x00, 0x03, 0x03, 0xC0, 0xF1, 0x83,
            0x19, 0x60,
        ])
        let sps2 = Data([0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9])
        let pps1 = Data([0x68, 0xEE, 0x3C, 0x80])

        var avcTag = Data([0xAA, 0xBB])  // leading prefix to test non-zero startIndex slice
        avcTag.append(contentsOf: [0x17, 0x00, 0x00, 0x00, 0x00])  // FLV video sequence header
        // AVCDecoderConfigurationRecord with 2 SPS entries and 2-byte NAL length (0xFD)
        avcTag.append(contentsOf: [0x01, 0x64, 0x00, 0x1F, 0xFD])
        avcTag.append(0xE2)  // numSPS = 2
        avcTag.append(contentsOf: UInt16(sps1.count).bigEndianBytes)
        avcTag.append(sps1)
        avcTag.append(contentsOf: UInt16(sps2.count).bigEndianBytes)
        avcTag.append(sps2)
        avcTag.append(0x01)  // numPPS = 1
        avcTag.append(contentsOf: UInt16(pps1.count).bigEndianBytes)
        avcTag.append(pps1)

        let slice = avcTag.dropFirst(2)
        XCTAssertEqual(slice.startIndex, 2)

        let config = try FLVDemuxer.parseAVCSequenceHeader(slice)
        XCTAssertEqual(config.sps, sps1)
        XCTAssertEqual(config.pps, pps1)
        XCTAssertEqual(config.naluLengthSize, 2)

        // Verify FLVMuxer preserves actual 2-byte nalUnitHeaderLength (0xFD, not hardcoded 0xFF)
        let formatDesc = try config.createFormatDescription()
        let muxedSeqHeader = try FLVMuxer.createVideoSequenceHeader(from: formatDesc)
        // Byte 5..9 of FLV sequence header payload is AVCDecoderConfigurationRecord[0..4]; index 9 is lengthSizeMinusOne
        XCTAssertEqual(muxedSeqHeader[9], 0xFD)

        // Verify NotSync attachment is accurately mutated for both keyframes and P-frames
        let keyframe = FLVDemuxer.VideoFrame(
            nalus: [Data([0x65, 0x88, 0x84])],
            isKeyframe: true,
            compositionTime: 0,
            pts: CMTime(value: 0, timescale: 1000),
            dts: CMTime(value: 0, timescale: 1000)
        )
        let keySample = try FLVDemuxer.createVideoSampleBuffer(frame: keyframe, formatDescription: formatDesc, naluLengthSize: 2)
        let keyAttachments = CMSampleBufferGetSampleAttachmentsArray(keySample, createIfNecessary: false) as? [[CFString: Any]]
        XCTAssertEqual(keyAttachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool, false)

        let pFrame = FLVDemuxer.VideoFrame(
            nalus: [Data([0x41, 0x9A, 0x22])],
            isKeyframe: false,
            compositionTime: 0,
            pts: CMTime(value: 33, timescale: 1000),
            dts: CMTime(value: 33, timescale: 1000)
        )
        let pSample = try FLVDemuxer.createVideoSampleBuffer(frame: pFrame, formatDescription: formatDesc, naluLengthSize: 2)
        let pAttachments = CMSampleBufferGetSampleAttachmentsArray(pSample, createIfNecessary: false) as? [[CFString: Any]]
        XCTAssertEqual(pAttachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool, true)
    }

    func testFLVDemuxerRejectsEmptyParameterSetsAndEmptyFramesWithoutTrapping() throws {
        let emptyConfig = FLVDemuxer.AVCDecoderConfig(
            sps: Data(),
            pps: Data(),
            profileIndication: 0x42,
            profileCompatibility: 0,
            levelIndication: 0x1E,
            naluLengthSize: 4
        )
        XCTAssertThrowsError(try emptyConfig.createFormatDescription())

        // Valid format description to test empty NALU / audio frame rejection
        let validConfig = FLVDemuxer.AVCDecoderConfig(
            sps: Data([
                0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0x50,
                0x05, 0xBB, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00,
                0x10, 0x00, 0x00, 0x03, 0x03, 0xC0, 0xF1, 0x83,
                0x19, 0x60,
            ]),
            pps: Data([0x68, 0xEE, 0x3C, 0x80]),
            profileIndication: 0x64,
            profileCompatibility: 0x00,
            levelIndication: 0x1F,
            naluLengthSize: 4
        )
        let videoFormat = try validConfig.createFormatDescription()
        let emptyVideo = FLVDemuxer.VideoFrame(nalus: [], isKeyframe: false, compositionTime: 0, pts: .zero, dts: .zero)
        XCTAssertThrowsError(try FLVDemuxer.createVideoSampleBuffer(frame: emptyVideo, formatDescription: videoFormat, naluLengthSize: 4))

        let audioConfig = FLVDemuxer.AACDecoderConfig(audioSpecificConfig: Data([0x11, 0x90]), sampleRate: 48000, channelCount: 2)
        let audioFormat = try audioConfig.createFormatDescription()
        let emptyAudio = FLVDemuxer.AudioFrame(data: Data(), pts: .zero)
        XCTAssertThrowsError(try FLVDemuxer.createAudioSampleBuffer(frame: emptyAudio, formatDescription: audioFormat))
    }

    func testFLVMuxerMetadataUsesUTF8ByteLengthAndSafeTimestamps() throws {
        let emojiValue = "Live 🎬🚀"
        let metadata = FLVMuxer.createMetadata(
            width: 1280,
            height: 720,
            framerate: 30,
            videoBitrate: 2_500_000,
            audioBitrate: 128_000,
            customFields: ["title": emojiValue]
        )
        var parser = AMF0Parser(data: metadata)
        let values = try parser.readAllValues()
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[0], .string("@setDataFrame"))
        XCTAssertEqual(values[1], .string("onMetaData"))
        XCTAssertEqual(values[2].objectValue?["title"], .string(emojiValue))

        XCTAssertEqual(FLVMuxer.timestampMilliseconds(from: .invalid), 0)
        XCTAssertEqual(FLVMuxer.timestampMilliseconds(from: .indefinite), 0)
        XCTAssertEqual(FLVMuxer.timestampMilliseconds(from: CMTime(seconds: -5, preferredTimescale: 1000)), 0)
        XCTAssertEqual(FLVMuxer.timestampMilliseconds(from: CMTime(seconds: 1.5, preferredTimescale: 1000)), 1500)
    }

    // MARK: - RTMP URL TLS & Port Validation

    func testRTMPURLParsingEnablesTLSAndPort443ForRTMPSAndRejectsBadPorts() {
        // Publisher URL parsing
        let pubRtmps = RTMPPublisher.parseRTMPURL("rtmps://live-api-s.facebook.com/rtmp")
        XCTAssertEqual(pubRtmps?.useTLS, true)
        XCTAssertEqual(pubRtmps?.port, 443)
        XCTAssertEqual(pubRtmps?.app, "rtmp")

        let pubRtmp = RTMPPublisher.parseRTMPURL("rtmp://ingest.example.com/app")
        XCTAssertEqual(pubRtmp?.useTLS, false)
        XCTAssertEqual(pubRtmp?.port, 1935)

        XCTAssertNil(RTMPPublisher.parseRTMPURL("rtmp://ingest.example.com:0/app"))
        XCTAssertNil(RTMPPublisher.parseRTMPURL("rtmp://ingest.example.com:70000/app"))
        XCTAssertNil(RTMPPublisher.parseRTMPURL("https://ingest.example.com/app"))

        // Subscriber URL parsing
        let subRtmps = RTMPSubscriber.parseRTMPURL("rtmps://stream.example.com/live")
        XCTAssertEqual(subRtmps?.useTLS, true)
        XCTAssertEqual(subRtmps?.port, 443)
        XCTAssertEqual(subRtmps?.tcUrl, "rtmps://stream.example.com/live")

        let subCustom = RTMPSubscriber.parseRTMPURL("rtmp://stream.example.com:1936/live")
        XCTAssertEqual(subCustom?.useTLS, false)
        XCTAssertEqual(subCustom?.port, 1936)
        XCTAssertEqual(subCustom?.tcUrl, "rtmp://stream.example.com:1936/live")

        XCTAssertNil(RTMPSubscriber.parseRTMPURL("rtmp://stream.example.com:0/live"))
        XCTAssertNil(RTMPSubscriber.parseRTMPURL("rtmp://stream.example.com:99999/live"))
        XCTAssertNil(RTMPSubscriber.parseRTMPURL("http://stream.example.com/live"))
    }

    // MARK: - NTDF Policy Preservation, Decryptor Safety & KAS HTTPS Enforcement

    func testNTDFPolicyRotationPreservesCallerAccessControlAttributes() throws {
        let originalPolicy = """
        {
            "uuid": "00000000-0000-0000-0000-000000000001",
            "body": {
                "dataAttributes": ["https://arkavo.net/attr/tier/value/vip"],
                "dissem": ["user-123"]
            }
        }
        """
        let (rotatedData, rotatedUUID) = NTDFStreamingManager.buildPolicyData(
            from: Data(originalPolicy.utf8),
            freshUUID: "11111111-1111-1111-1111-111111111111"
        )

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: rotatedData) as? [String: Any])
        XCTAssertEqual(json["uuid"] as? String, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(rotatedUUID, "11111111-1111-1111-1111-111111111111")
        let body = try XCTUnwrap(json["body"] as? [String: Any])
        XCTAssertEqual(body["dataAttributes"] as? [String], ["https://arkavo.net/attr/tier/value/vip"])
        XCTAssertEqual(body["dissem"] as? [String], ["user-123"])
    }

    func testStreamingCollectionDecryptorRejectsShortPayloadAndCapsRotatedKeys() async throws {
        let key = SymmetricKey(size: .bits256)
        let baseDecryptor = NanoTDFCollectionDecryptor.withUnwrappedKey(symmetricKey: key, cipher: .aes256GCM128)
        let streamingDecryptor = StreamingCollectionDecryptor(
            initialDecryptor: baseDecryptor,
            cipher: .aes256GCM128,
            headerDigest: Data([0x00])
        )

        // Crafted 6-byte frame with payloadLength = 0 (< 16-byte GCM tag) must throw, not trap
        let craftedShort = Data([0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
        do {
            _ = try await streamingDecryptor.decrypt(craftedShort)
            XCTFail("Expected decryptionFailed for payload shorter than tag size")
        } catch let error as NTDFSubscriberError {
            guard case .decryptionFailed = error else {
                return XCTFail("Expected decryptionFailed, got \(error)")
            }
        }

        // Also test non-zero startIndex Data slice
        let paddedShort = Data([0xFF, 0xFF]) + craftedShort
        do {
            _ = try await streamingDecryptor.decrypt(paddedShort.dropFirst(2))
            XCTFail("Expected decryptionFailed for sliced short payload")
        } catch is NTDFSubscriberError {
            // Expected
        }

        // Adding more than maxCachedDecryptors keys must cap memory at maxCachedDecryptors (8)
        for i in 1 ... 12 {
            let rotated = NanoTDFCollectionDecryptor.withUnwrappedKey(
                symmetricKey: SymmetricKey(size: .bits256),
                cipher: .aes256GCM128
            )
            await streamingDecryptor.addAlternateDecryptor(rotated, headerDigest: Data([UInt8(i)]))
        }
        let count = await streamingDecryptor.cachedDecryptorCount
        XCTAssertEqual(count, StreamingCollectionDecryptor.maxCachedDecryptors)
    }

    func testSPKIPEMFormatIsValidRFC7468SubjectPublicKeyInfo() throws {
        let priv = P256.KeyAgreement.PrivateKey()
        let pem = try StreamingCollectionDecryptor.convertToSPKIPEM(
            compressedKey: priv.publicKey.compressedRepresentation
        )
        XCTAssertTrue(pem.hasPrefix("-----BEGIN PUBLIC KEY-----\n"))
        XCTAssertTrue(pem.hasSuffix("\n-----END PUBLIC KEY-----"))
        // Must parse cleanly as standard SPKI PEM
        let reparsed = try P256.KeyAgreement.PublicKey(pemRepresentation: pem)
        XCTAssertEqual(reparsed.compressedRepresentation, priv.publicKey.compressedRepresentation)
    }

    func testKASPublicKeyServiceRejectsCleartextNonLoopbackHTTPAndPreservesPort() throws {
        let insecureURL = try XCTUnwrap(URL(string: "http://kas.example.com"))
        XCTAssertThrowsError(try KASPublicKeyService.validatedPublicKeyURL(for: insecureURL))

        let loopbackURL = try XCTUnwrap(URL(string: "http://localhost:8080"))
        let resolvedLoopback = try KASPublicKeyService.validatedPublicKeyURL(for: loopbackURL)
        XCTAssertEqual(resolvedLoopback.port, 8080)

        let customPortHTTPS = try XCTUnwrap(URL(string: "https://kas.example.com:8443"))
        let locator = try KASPublicKeyService.makeResourceLocator(for: customPortHTTPS)
        XCTAssertEqual(locator.body, "kas.example.com:8443")
    }

    // MARK: - AudioEncoder Invalid PTS & Format Validation

    private func makePCMBuffer(
        frames: Int,
        pts: CMTime,
        sampleRate: Double = 48000,
        channels: AVAudioChannelCount = 2,
        commonFormat: AVAudioCommonFormat = .pcmFormatInt16,
        interleaved: Bool = true
    ) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: interleaved
        ))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        if commonFormat == .pcmFormatInt16, let ch = pcm.int16ChannelData {
            for i in 0 ..< frames * Int(channels) {
                ch[0][i] = Int16(truncatingIfNeeded: (i * 29) % 2000 - 1000)
            }
        }

        var formatDescription: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ), noErr)
        var sampleBuffer: CMSampleBuffer?
        let initialPTS = pts.isValid ? pts : .zero
        XCTAssertEqual(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: try XCTUnwrap(formatDescription),
            sampleCount: frames,
            presentationTimeStamp: initialPTS,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ), noErr)
        let buffer = try XCTUnwrap(sampleBuffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        ), noErr)
        if !pts.isValid {
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var retimed: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: buffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &retimed
            ), noErr)
            return try XCTUnwrap(retimed)
        }
        return buffer
    }

    func testAudioEncoderIgnoresInitialInvalidPTSAndRecoversOnValidFrames() throws {
        let encoder = try AudioEncoder()
        let output = Mutex<[EncodedAudioFrame]>([])
        encoder.onFrame = { frame in output.withLock { $0.append(frame) } }

        // First buffer has .invalid PTS — must NOT poison nextOutputPTS
        encoder.feed(try makePCMBuffer(frames: 1024, pts: .invalid))
        XCTAssertTrue(output.withLock { $0.isEmpty })

        // Feed unsupported sample rate (44.1 kHz) — must be ignored safely
        encoder.feed(try makePCMBuffer(frames: 1024, pts: CMTime(value: 0, timescale: 44100), sampleRate: 44100))
        XCTAssertTrue(output.withLock { $0.isEmpty })

        // Subsequent valid 48kHz stereo Int16 buffers must anchor cleanly and emit numeric-PTS AAC frames
        for i in 0 ..< 6 {
            let pts = CMTime(value: CMTimeValue(10 * 48000 + i * 1024), timescale: 48000)
            encoder.feed(try makePCMBuffer(frames: 1024, pts: pts))
        }

        let frames = output.withLock { $0 }
        XCTAssertGreaterThanOrEqual(frames.count, 4)
        for frame in frames {
            XCTAssertTrue(frame.pts.isNumeric, "Output frame PTS must be numeric after initial .invalid buffer")
            XCTAssertGreaterThanOrEqual(frame.pts.seconds, 10.0)
        }
    }
}
