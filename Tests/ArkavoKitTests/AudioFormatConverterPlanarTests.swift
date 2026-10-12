import AVFoundation
import CoreMedia
import XCTest
@testable import ArkavoRecorder

/// ScreenCaptureKit delivers system audio as non-interleaved (planar) Float32 stereo. The
/// converter must keep the frame count and put each plane in its own channel; it used to
/// count both planes' bytes as frames (2x the audio, so streamed audio ran ~2x real time and
/// Twitch never took the broadcast online) and to copy both planes into the left channel.
final class AudioFormatConverterPlanarTests: XCTestCase {
    /// A planar Float32 stereo buffer: left = +0.5, right = -0.25, `frames` frames.
    private func planarStereoBuffer(frames: Int, pts: CMTime = .zero) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false
        ))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let channels = try XCTUnwrap(pcm.floatChannelData)
        for i in 0 ..< frames {
            channels[0][i] = 0.5
            channels[1][i] = -0.25
        }

        var formatDescription: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription
        ), noErr)

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: pts, decodeTimeStamp: .invalid
        )
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
        ), noErr)
        let buffer = try XCTUnwrap(sampleBuffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList
        ), noErr)
        return buffer
    }

    private func interleavedInt16(_ buffer: CMSampleBuffer) throws -> [Int16] {
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        XCTAssertEqual(CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
        ), noErr)
        let raw = try XCTUnwrap(pointer)
        return raw.withMemoryRebound(to: Int16.self, capacity: length / 2) {
            Array(UnsafeBufferPointer(start: $0, count: length / 2))
        }
    }

    func testPlanarStereoKeepsItsFrameCount() throws {
        let converter = AudioFormatConverter(targetSampleRate: 48000, targetChannels: 2, sourceID: "test")
        let output = try XCTUnwrap(converter.convert(try planarStereoBuffer(frames: 1024)))

        XCTAssertEqual(CMSampleBufferGetNumSamples(output), 1024)
    }

    func testPlanarStereoKeepsEachChannelInPlace() throws {
        let converter = AudioFormatConverter(targetSampleRate: 48000, targetChannels: 2, sourceID: "test")
        let samples = try interleavedInt16(try XCTUnwrap(converter.convert(try planarStereoBuffer(frames: 480))))

        XCTAssertEqual(samples.count, 960)
        let left = stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
        let right = stride(from: 1, to: samples.count, by: 2).map { samples[$0] }
        // +0.5 and -0.25 full scale, allowing for dither/rounding.
        XCTAssertTrue(left.allSatisfy { abs(Int($0) - 16384) <= 2 }, "left: \(left.prefix(4))")
        XCTAssertTrue(right.allSatisfy { abs(Int($0) + 8192) <= 2 }, "right: \(right.prefix(4))")
    }

    func testRepeatedConversionsDoNotDuplicateAudio() throws {
        let converter = AudioFormatConverter(targetSampleRate: 48000, targetChannels: 2, sourceID: "test")
        var total = 0
        for i in 0 ..< 10 {
            let input = try planarStereoBuffer(frames: 480, pts: CMTime(value: CMTimeValue(i * 480), timescale: 48000))
            total += CMSampleBufferGetNumSamples(try XCTUnwrap(converter.convert(input)))
        }

        XCTAssertEqual(total, 4800, "10 buffers of 480 frames must convert to 4800 frames, not more")
    }
}
