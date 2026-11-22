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

    // MARK: - PR #88 Regression Fixes

    func testRTMPPublisherTimestampNormalizationIncompatibleClockDomains() async {
        let publisher = RTMPPublisher()
        let hostAudioBase: CMTimeValue = 50_000 * 48_000

        // (a1) 0-based stream-relative video arrives first, then 50,000s host-clock audio
        let v0 = await publisher.normalizeTimestamp(CMTime(value: 0, timescale: 1000), for: .video)
        let v1 = await publisher.normalizeTimestamp(CMTime(value: 33, timescale: 1000), for: .video)
        let a0 = await publisher.normalizeTimestamp(CMTime(value: hostAudioBase, timescale: 48_000), for: .audio)
        let a1 = await publisher.normalizeTimestamp(CMTime(value: hostAudioBase + 1008, timescale: 48_000), for: .audio)
        let v2 = await publisher.normalizeTimestamp(CMTime(value: 66, timescale: 1000), for: .video)

        XCTAssertEqual(v0, 0)
        XCTAssertEqual(v1, 33)
        XCTAssertEqual(a0, 0)
        XCTAssertEqual(a1, 21)
        XCTAssertEqual(v2, 66)

        // Reset anchors on disconnect, then verify reverse arrival order (audio first, video second)
        await publisher.disconnect()

        let aRev0 = await publisher.normalizeTimestamp(CMTime(value: hostAudioBase, timescale: 48_000), for: .audio)
        let aRev1 = await publisher.normalizeTimestamp(CMTime(value: hostAudioBase + 2016, timescale: 48_000), for: .audio)
        let vRev0 = await publisher.normalizeTimestamp(CMTime(value: 0, timescale: 1000), for: .video)
        let vRev1 = await publisher.normalizeTimestamp(CMTime(value: 33, timescale: 1000), for: .video)

        XCTAssertEqual(aRev0, 0)
        XCTAssertEqual(aRev1, 42)
        XCTAssertEqual(vRev0, 0)
        XCTAssertEqual(vRev1, 33)
    }

    func testRTMPPublisherTimestampNormalizationSameClockDomainPreservesOffset() async {
        let publisher = RTMPPublisher()

        // (b1) Same clock domain, second track starts later within 10s:
        // audio arrives at 100.0s, video arrives at 100.5s -> preserves exact 500ms offset
        let a0 = await publisher.normalizeTimestamp(CMTime(value: 100_000, timescale: 1000), for: .audio)
        let v0 = await publisher.normalizeTimestamp(CMTime(value: 100_500, timescale: 1000), for: .video)
        let a1 = await publisher.normalizeTimestamp(CMTime(value: 100_500, timescale: 1000), for: .audio)
        let v1 = await publisher.normalizeTimestamp(CMTime(value: 101_000, timescale: 1000), for: .video)

        XCTAssertEqual(a0, 0)
        XCTAssertEqual(v0, 500)
        XCTAssertEqual(a1, 500)
        XCTAssertEqual(v1, 1000)

        // (b2) Video starts first at 100.0s, audio starts later at 100.5s -> preserves exact 500ms offset
        await publisher.disconnect()

        let vLate0 = await publisher.normalizeTimestamp(CMTime(value: 100_000, timescale: 1000), for: .video)
        let aLate0 = await publisher.normalizeTimestamp(CMTime(value: 100_500, timescale: 1000), for: .audio)
        let vLate1 = await publisher.normalizeTimestamp(CMTime(value: 100_500, timescale: 1000), for: .video)
        let aLate1 = await publisher.normalizeTimestamp(CMTime(value: 101_000, timescale: 1000), for: .audio)

        XCTAssertEqual(vLate0, 0)
        XCTAssertEqual(aLate0, 500)
        XCTAssertEqual(vLate1, 500)
        XCTAssertEqual(aLate1, 1000)

        // (b3) Video arrives first at 100.5s (emits 0ms), then earlier audio arrives at 100.0s:
        // emitted anchor must remain frozen at 100.5s (zero jump on next video frame),
        // pre-anchor audio clamps to 0ms, and subsequent frames align in exact sync.
        await publisher.disconnect()

        let vRev0 = await publisher.normalizeTimestamp(CMTime(value: 100_500, timescale: 1000), for: .video)
        let aRev0 = await publisher.normalizeTimestamp(CMTime(value: 100_000, timescale: 1000), for: .audio)
        let vRev1 = await publisher.normalizeTimestamp(CMTime(value: 101_000, timescale: 1000), for: .video)
        let aRev1 = await publisher.normalizeTimestamp(CMTime(value: 101_000, timescale: 1000), for: .audio)

        XCTAssertEqual(vRev0, 0)
        XCTAssertEqual(aRev0, 0)
        XCTAssertEqual(vRev1, 500)
        XCTAssertEqual(aRev1, 500)

        // (b4) Symmetric case: audio arrives first at 100.5s (emits 0ms), then earlier video at 100.0s
        await publisher.disconnect()

        let aFirst0 = await publisher.normalizeTimestamp(CMTime(value: 100_500, timescale: 1000), for: .audio)
        let vSecond0 = await publisher.normalizeTimestamp(CMTime(value: 100_000, timescale: 1000), for: .video)
        let aFirst1 = await publisher.normalizeTimestamp(CMTime(value: 101_000, timescale: 1000), for: .audio)
        let vSecond1 = await publisher.normalizeTimestamp(CMTime(value: 101_000, timescale: 1000), for: .video)

        XCTAssertEqual(aFirst0, 0)
        XCTAssertEqual(vSecond0, 0)
        XCTAssertEqual(aFirst1, 500)
        XCTAssertEqual(vSecond1, 500)
    }

    func testRTMPSubscriberMetadataDimensionRejectsIntMaxAndTwoTo63WithoutTrapping() async {
        let twoTo63 = Double(UInt64(1) << 63)

        XCTAssertNil(RTMPSubscriber.sanitizedMetadataDimension(Double(Int.max)))
        XCTAssertNil(RTMPSubscriber.sanitizedMetadataDimension(twoTo63))
        XCTAssertNil(RTMPSubscriber.sanitizedMetadataDimension(Double(Int32.max) + 1.0))
        XCTAssertNil(RTMPSubscriber.sanitizedMetadataDimension(.nan))
        XCTAssertNil(RTMPSubscriber.sanitizedMetadataDimension(.infinity))
        XCTAssertNil(RTMPSubscriber.sanitizedMetadataDimension(-.infinity))
        XCTAssertNil(RTMPSubscriber.sanitizedMetadataDimension(-1.0))

        XCTAssertEqual(RTMPSubscriber.sanitizedMetadataDimension(0.0), 0)
        XCTAssertEqual(RTMPSubscriber.sanitizedMetadataDimension(1920.0), 1920)
        XCTAssertEqual(RTMPSubscriber.sanitizedMetadataDimension(Double(Int32.max)), Int(Int32.max))

        let subscriber = RTMPSubscriber()
        let defaultMediaReadTimeout = await subscriber.mediaReadTimeout
        XCTAssertNil(defaultMediaReadTimeout)

        let invalidPayload = AMF0.encodeObject([
            "width": .number(Double(Int.max)),
            "height": .number(twoTo63),
        ])
        await subscriber.handleMetadata(invalidPayload)
        let rejected = await subscriber.currentMetadata
        XCTAssertNil(rejected.width)
        XCTAssertNil(rejected.height)

        let validPayload = AMF0.encodeObject([
            "width": .number(1920.0),
            "height": .number(1080.0),
        ])
        await subscriber.handleMetadata(validPayload)
        let accepted = await subscriber.currentMetadata
        XCTAssertEqual(accepted.width, 1920)
        XCTAssertEqual(accepted.height, 1080)
    }

    private func makeTestPixelBuffer(width: Int = 1280, height: Int = 720) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private final class FrameCounter: Sendable {
        private let value = Mutex<Int>(0)
        func increment() { value.withLock { $0 += 1 } }
        func reset() { value.withLock { $0 = 0 } }
        var count: Int { value.withLock { $0 } }
    }

    func testVideoEncoderStopStartPreservesReplacementCallbackContext() async throws {
        let encoder = VideoEncoder(quality: .performance)
        let counter = FrameCounter()
        encoder.onFrame = { _ in
            counter.increment()
        }

        let pixelBuffer = try makeTestPixelBuffer(width: 1280, height: 720)

        // Sequential start -> stop -> start must preserve an active callback context
        try encoder.start()
        XCTAssertTrue(encoder.hasActiveCallbackContext)
        try encoder.encode(pixelBuffer, timestamp: CMTime(value: 0, timescale: 30))

        encoder.stop()
        XCTAssertFalse(encoder.hasActiveCallbackContext)

        try encoder.start()
        XCTAssertTrue(encoder.hasActiveCallbackContext)

        counter.reset()
        for i in 1 ... 5 {
            try encoder.encode(pixelBuffer, timestamp: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        for _ in 0 ..< 100 {
            if counter.count > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(counter.count, 0, "Restarted VideoEncoder session must deliver encoded frames")

        // Concurrent overlapping stop/start must never leave a running session with a deactivated context
        for iteration in 0 ..< 5 {
            try encoder.start()
            try encoder.encode(pixelBuffer, timestamp: CMTime(value: CMTimeValue(10 + iteration * 2), timescale: 30))
            try encoder.encode(pixelBuffer, timestamp: CMTime(value: CMTimeValue(11 + iteration * 2), timescale: 30))

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    encoder.stop()
                }
                group.addTask {
                    try? encoder.start()
                }
            }

            if encoder.isRunning {
                XCTAssertTrue(
                    encoder.hasActiveCallbackContext,
                    "Concurrent stop() must never deactivate a replacement session's callback context"
                )
            }
        }

        // Ensure encoder is started and still delivers frames after concurrent stop/start cycles
        try encoder.start()
        XCTAssertTrue(encoder.hasActiveCallbackContext)
        counter.reset()
        for i in 100 ... 104 {
            try encoder.encode(pixelBuffer, timestamp: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        for _ in 0 ..< 100 {
            if counter.count > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(counter.count, 0, "VideoEncoder must remain active after concurrent stop/start")

        encoder.stop()
        XCTAssertFalse(encoder.hasActiveCallbackContext)
    }

    func testVideoEncoderOnFrameReentrantReadAndMutationDoesNotDeadlock() async throws {
        let encoder = VideoEncoder(quality: .performance)
        try encoder.start()
        defer { encoder.stop() }

        let firstCallbackSawHandler = Mutex<Bool>(false)
        let replacementCallbackCount = FrameCounter()

        // (1) Deterministic synchronous re-entrancy while sessionLock is held:
        // reading and mutating `encoder.onFrame` from inside an active callback must not deadlock.
        encoder.onFrame = { [weak encoder] _ in
            guard let encoder else { return }
            let hadHandler = encoder.onFrame != nil
            firstCallbackSawHandler.withLock { $0 = hadHandler }
            encoder.onFrame = { [weak encoder] _ in
                replacementCallbackCount.increment()
                encoder?.onFrame = nil
            }
        }

        let dummyFrame = EncodedVideoFrame(data: Data([0x00, 0x00, 0x00, 0x01, 0x65]), pts: .zero, isKeyframe: true)
        encoder.invokeActiveCallbackWhileHoldingSessionLockForTesting(dummyFrame)
        XCTAssertTrue(firstCallbackSawHandler.withLock { $0 })
        XCTAssertNotNil(encoder.onFrame)

        encoder.invokeActiveCallbackWhileHoldingSessionLockForTesting(dummyFrame)
        XCTAssertEqual(replacementCallbackCount.count, 1)
        XCTAssertNil(encoder.onFrame)

        // Subsequent callback invocation after clearing onFrame is a no-op
        encoder.invokeActiveCallbackWhileHoldingSessionLockForTesting(dummyFrame)
        XCTAssertEqual(replacementCallbackCount.count, 1)

        // (2) Real VideoToolbox encoding with re-entrant onFrame read & clear
        let realCallbacks = FrameCounter()
        let realCallbackSawHandler = Mutex<Bool>(false)
        encoder.onFrame = { [weak encoder] _ in
            guard let encoder else { return }
            let hadHandler = encoder.onFrame != nil
            realCallbackSawHandler.withLock { $0 = $0 || hadHandler }
            realCallbacks.increment()
            encoder.onFrame = nil
        }

        let pixelBuffer = try makeTestPixelBuffer(width: 1280, height: 720)
        for i in 0 ..< 5 {
            try encoder.encode(pixelBuffer, timestamp: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        for _ in 0 ..< 100 {
            if realCallbacks.count > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(realCallbacks.count, 1, "Re-entrant onFrame clear during real encoding must fire without deadlocking")
        XCTAssertTrue(realCallbackSawHandler.withLock { $0 })
        XCTAssertNil(encoder.onFrame)
    }

    func testNTDFTokenBuilderEmbedsPlaintextPolicyClaimsAndValidatesKASURL() async throws {
        let kasPrivateKey = P256.KeyAgreement.PrivateKey()
        let kasPublicKey = kasPrivateKey.publicKey.compressedRepresentation

        let payload = NTDFTokenPayload(
            subId: UUID(),
            flags: [.profile, .webAuthn],
            scopes: ["openid", "profile"],
            attrs: [(NTDFAttributeType.subscriptionTier.rawValue, 2)],
            iat: 1_700_000_000,
            exp: 1_700_003_600,
            aud: "https://kas.example.com:8443",
            deviceId: "device-abc"
        )
        let expectedClaimsBytes = try payload.toBytesChecked()

        let builder = NTDFTokenBuilder(kasPublicKey: kasPublicKey, kasURL: "https://kas.example.com:8443")
        let z85Token = try await builder.build(payload: payload)

        let decodedBytes = try XCTUnwrap(Z85.decode(z85Token))
        let parser = BinaryParser(data: decodedBytes)
        let header = try parser.parseHeader()

        XCTAssertEqual(header.policy.type, .embeddedPlaintext)
        XCTAssertEqual(header.policy.body?.body, expectedClaimsBytes)
        XCTAssertEqual(header.payloadKeyAccess.kasLocator.body, "kas.example.com:8443")

        // Non-loopback cleartext HTTP KAS URL must still be rejected
        let insecureBuilder = NTDFTokenBuilder(kasPublicKey: kasPublicKey, kasURL: "http://kas.example.com")
        do {
            _ = try await insecureBuilder.build(payload: payload)
            XCTFail("Expected non-loopback HTTP KAS URL to be rejected")
        } catch let error as NTDFTokenError {
            guard case .invalidKeyFormat = error else {
                return XCTFail("Expected invalidKeyFormat, got \(error)")
            }
        }
    }
}
