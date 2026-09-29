import Testing
import AVFoundation
import CoreMedia
@testable import ArkavoRecorder

struct AudioMixerTests {
    /// 48 kHz stereo Int16 interleaved buffer filled with `value`, `frames` long, PTS `pts`.
    static func buffer(frames: Int, value: Int16, pts: CMTime) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0)
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        var samples = [Int16](repeating: value, count: frames * 2)
        let length = samples.count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
        samples.withUnsafeMutableBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
        var out: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: desc!,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &out)
        return out!
    }

    static func samples(_ sb: CMSampleBuffer) -> [Int16] {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return [] }
        var length = 0; var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
        return ptr!.withMemoryRebound(to: Int16.self, capacity: length / 2) { Array(UnsafeBufferPointer(start: $0, count: length / 2)) }
    }

    @Test("A single source passes through untouched")
    func singleSourcePassthrough() {
        let mixer = AudioMixer()
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        mixer.addSample(Self.buffer(frames: 960, value: 100, pts: .zero), from: "microphone")
        #expect(out.count == 1)
        #expect(Self.samples(out[0]).allSatisfy { $0 == 100 })
    }

    @Test("A voice buffer is mixed once, then the mic continues alone")
    func voiceIsConsumedOnce() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        mixer.voiceDuckAmount = 1.0
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        mixer.addSample(Self.buffer(frames: 960, value: 100, pts: .zero), from: "microphone")   // clock, alone → 100
        mixer.addSample(Self.buffer(frames: 960, value: 50, pts: .zero), from: "muse-voice")    // queued, no emission
        mixer.addSample(Self.buffer(frames: 960, value: 100, pts: CMTime(value: 960, timescale: 48000)), from: "microphone") // 150
        mixer.addSample(Self.buffer(frames: 960, value: 100, pts: CMTime(value: 1920, timescale: 48000)), from: "microphone") // 100
        #expect(out.count == 3)
        #expect(Self.samples(out[0]).first == 100)
        #expect(Self.samples(out[1]).first == 150)
        #expect(Self.samples(out[2]).first == 100)
    }

    @Test("Only the clock source emits; a non-clock source never produces output on its own")
    func nonClockSourceDoesNotEmit() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        var count = 0
        mixer.onMixedSample = { _ in count += 1 }
        mixer.addSample(Self.buffer(frames: 960, value: 1, pts: .zero), from: "microphone")
        for _ in 0..<5 { mixer.addSample(Self.buffer(frames: 960, value: 1, pts: .zero), from: "muse-voice") }
        #expect(count == 1)
    }

    @Test("A partial voice buffer is zero-filled to the clock frame length")
    func shortVoiceIsZeroFilled() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        mixer.voiceDuckAmount = 1.0
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        mixer.addSample(Self.buffer(frames: 960, value: 0, pts: .zero), from: "microphone")
        mixer.addSample(Self.buffer(frames: 480, value: 50, pts: .zero), from: "muse-voice")
        mixer.addSample(Self.buffer(frames: 960, value: 0, pts: CMTime(value: 960, timescale: 48000)), from: "microphone")
        let s = Self.samples(out[1])
        #expect(s[0] == 50)
        #expect(s[s.count - 1] == 0)
    }

    @Test("The mic is ducked while voice is queued and for the hangover after")
    func duckingFollowsVoiceActivity() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        mixer.voiceDuckAmount = 0.5
        mixer.voiceDuckHangover = 0   // exactly one frame after the FIFO empties is undocked
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        mixer.addSample(Self.buffer(frames: 960, value: 100, pts: .zero), from: "microphone")
        mixer.addSample(Self.buffer(frames: 960, value: 0, pts: .zero), from: "muse-voice")
        mixer.addSample(Self.buffer(frames: 960, value: 100, pts: CMTime(value: 960, timescale: 48000)), from: "microphone") // ducked → 50
        mixer.addSample(Self.buffer(frames: 960, value: 100, pts: CMTime(value: 1920, timescale: 48000)), from: "microphone") // → 100
        #expect(Self.samples(out[1]).first == 50)
        #expect(Self.samples(out[2]).first == 100)
    }

    @Test("Voice alone (no mic) is its own clock")
    func voiceAloneIsClock() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        mixer.addSample(Self.buffer(frames: 960, value: 7, pts: .zero), from: "muse-voice")
        #expect(out.count == 1)
        #expect(Self.samples(out[0]).first == 7)
    }

    @Test("The output PTS is the clock buffer's PTS")
    func ptsFollowsClock() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        let pts = CMTime(value: 123_456, timescale: 48000)
        mixer.addSample(Self.buffer(frames: 960, value: 1, pts: pts), from: "microphone")
        mixer.addSample(Self.buffer(frames: 960, value: 1, pts: .zero), from: "muse-voice")
        let pts2 = CMTime(value: 124_416, timescale: 48000)
        mixer.addSample(Self.buffer(frames: 960, value: 1, pts: pts2), from: "microphone")
        #expect(CMSampleBufferGetPresentationTimeStamp(out[1]) == pts2)
    }
}
