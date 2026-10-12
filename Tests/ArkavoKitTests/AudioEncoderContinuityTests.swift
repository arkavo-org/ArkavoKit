import AVFoundation
import CoreMedia
import Synchronization
import XCTest
@testable import ArkavoMedia

/// The mixer hands the AAC encoder buffers that are not 1024 frames long. The encoder used to
/// encode one 1024-frame packet per 1024+ frames gathered and drop the rest, so a stream fed
/// 960-frame buffers kept about half its audio, with packets 40 ms apart for 21.3 ms of sound.
final class AudioEncoderContinuityTests: XCTestCase {
    private func pcmBuffer(frames: Int, pts: CMTime) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true
        ))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(pcm.int16ChannelData)[0]
        for i in 0 ..< frames * 2 { samples[i] = Int16(truncatingIfNeeded: (i * 37) % 2000 - 1000) }

        var formatDescription: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription
        ), noErr)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: try XCTUnwrap(formatDescription),
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ), noErr)
        let buffer = try XCTUnwrap(sampleBuffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList
        ), noErr)
        return buffer
    }

    /// Feeds `count` consecutive buffers of `frames` frames starting at 100 s and returns the
    /// AAC frames the encoder produced.
    private func encode(count: Int, frames: Int) throws -> [EncodedAudioFrame] {
        let encoder = try AudioEncoder()
        let output = Mutex<[EncodedAudioFrame]>([])
        encoder.onFrame = { frame in output.withLock { $0.append(frame) } }
        for i in 0 ..< count {
            let pts = CMTime(value: CMTimeValue(100 * 48000 + i * frames), timescale: 48000)
            encoder.feed(try pcmBuffer(frames: frames, pts: pts))
        }
        return output.withLock { $0 }
    }

    func testOddSizedBuffersKeepAllTheirAudio() throws {
        // 50 × 960 = 48 000 frames = 46.875 AAC packets; allow for encoder start-up latency.
        let frames = try encode(count: 50, frames: 960)
        XCTAssertGreaterThanOrEqual(frames.count, 44, "960-frame buffers must not lose audio")
    }

    /// Gaps that each stay under the resync threshold (a dropped capture buffer) used to be lost
    /// for good, so audio fell further behind video with every one.
    func testSmallGapsAddUpAndResync() throws {
        let encoder = try AudioEncoder()
        let output = Mutex<[EncodedAudioFrame]>([])
        encoder.onFrame = { frame in output.withLock { $0.append(frame) } }
        let frames = 960
        var input = CMTime(value: 100 * 48000, timescale: 48000)
        var fedEnd = input
        for i in 0 ..< 60 {
            encoder.feed(try pcmBuffer(frames: frames, pts: input))
            input = input + CMTime(value: CMTimeValue(frames), timescale: 48000)
            fedEnd = input
            // Every 5th buffer is followed by a 60 ms hole: 11 holes reach the encoder, 660 ms.
            if i % 5 == 4 { input = input + CMTime(value: 60, timescale: 1000) }
        }
        let last = try XCTUnwrap(output.withLock { $0.last })
        // Allowed: the queued remainder and look-ahead (under 70 ms) plus up to 100 ms of loss
        // not yet past the resync threshold. Lost holes would leave it 0.6+ s behind.
        let lag = (fedEnd - last.pts).seconds
        XCTAssertLessThan(lag, 0.2, "audio must stay level with its input, not \(lag) s behind")
    }

    func testPacketTimestampsAdvanceOnePacketAtATime() throws {
        let frames = try encode(count: 50, frames: 960)
        XCTAssertGreaterThan(frames.count, 1)
        let step = 1024.0 / 48000.0
        for (previous, next) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual((next.pts - previous.pts).seconds, step, accuracy: 0.0005)
        }
    }
}
