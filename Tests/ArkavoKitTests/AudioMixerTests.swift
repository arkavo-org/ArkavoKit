import Testing
import AVFoundation
import CoreMedia
@testable import ArkavoRecorder

/// Tests of mixing, ducking and clock selection build an unbuffered mixer (`prefillSeconds: 0`),
/// so a queued source plays at the next clock buffer; the jitter-buffer tests use the default.
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
        samples.withUnsafeMutableBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
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
        let mixer = AudioMixer(voiceSourceID: "muse-voice", prefillSeconds: 0)
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
        let mixer = AudioMixer(voiceSourceID: "muse-voice", prefillSeconds: 0)
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
        let mixer = AudioMixer(voiceSourceID: "muse-voice", prefillSeconds: 0)
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

    @Test("A pinned clock is not displaced by the voice delivering first")
    func pinnedClockWithVoiceFirst() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice", prefillSeconds: 0)
        mixer.voiceDuckAmount = 1.0
        mixer.setClockSource("microphone")
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        mixer.addSample(Self.buffer(frames: 960, value: 50, pts: .zero), from: "muse-voice")
        #expect(out.isEmpty)
        mixer.addSample(Self.buffer(frames: 960, value: 100, pts: .zero), from: "microphone")
        #expect(out.count == 1)
        #expect(Self.samples(out[0]).first == 150)
    }

    @Test("Once the other source is unregistered, the voice alone becomes the clock")
    func voiceIsClockAfterTheOtherSourceIsUnregistered() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        mixer.registerSource("microphone")
        mixer.registerSource("muse-voice")
        mixer.unregisterSource("microphone")
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        mixer.addSample(Self.buffer(frames: 960, value: 50, pts: .zero), from: "muse-voice")
        #expect(out.count == 1)
    }

    @Test("An unpinned voice is queued, not the clock, while another source is registered")
    func voiceIsNotAutoClockWhenOthersRegistered() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice", prefillSeconds: 0)
        mixer.voiceDuckAmount = 1.0
        mixer.registerSource("microphone")
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        mixer.addSample(Self.buffer(frames: 960, value: 50, pts: .zero), from: "muse-voice")
        #expect(out.isEmpty)
        mixer.addSample(Self.buffer(frames: 960, value: 100, pts: .zero), from: "microphone")
        #expect(out.count == 1)
        #expect(Self.samples(out[0]).first == 150)
        // The mic is now the clock: more voice does not emit.
        mixer.addSample(Self.buffer(frames: 960, value: 50, pts: .zero), from: "muse-voice")
        #expect(out.count == 1)
    }

    @Test("Pinning the clock drops that source's stale queued audio")
    func setClockSourceDropsStaleFifo() {
        let mixer = AudioMixer()
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        mixer.addSample(Self.buffer(frames: 960, value: 10, pts: .zero), from: "screen")       // screen is the clock
        mixer.addSample(Self.buffer(frames: 960, value: 500, pts: .zero), from: "microphone")  // queued backlog
        mixer.setClockSource("microphone")
        mixer.addSample(Self.buffer(frames: 960, value: 100, pts: .zero), from: "microphone")
        #expect(out.count == 2)
        #expect(Self.samples(out[1]).first == 100)   // not 600
    }

    @Test("reset() clears queued audio and the clock")
    func resetClearsFifosAndClock() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        mixer.voiceDuckAmount = 1.0
        mixer.setClockSource("microphone")
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        mixer.addSample(Self.buffer(frames: 960, value: 50, pts: .zero), from: "muse-voice")
        mixer.reset()
        // Clock is cleared: a different source now becomes the clock and emits.
        mixer.addSample(Self.buffer(frames: 960, value: 100, pts: .zero), from: "screen")
        #expect(out.count == 1)
        // Queued voice is gone.
        #expect(Self.samples(out[0]).first == 100)
    }

    @Test("Each FIFO holds at most 200 ms; the oldest samples are dropped")
    func fifoIsCapped() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        mixer.voiceDuckAmount = 1.0
        mixer.setClockSource("microphone")
        var out: [CMSampleBuffer] = []
        mixer.onMixedSample = { out.append($0) }
        // 1 s of voice as 100 x 10 ms buffers, values 1...100, with no clock ticks.
        for i in 1...100 {
            mixer.addSample(Self.buffer(frames: 480, value: Int16(i), pts: .zero), from: "muse-voice")
        }
        mixer.addSample(Self.buffer(frames: 12_000, value: 0, pts: .zero), from: "microphone")
        let s = Self.samples(out[0])
        #expect(s.count == 24_000)
        #expect(s[0] == 81)                 // only buffers 81...100 (last 200 ms = 20 x 10 ms) survive
        #expect(s[19_199] == 100)
        #expect(s[19_200] == 0)             // 9,600 frames of voice, rest zero-filled
    }

    // MARK: - Jitter buffer

    /// Clock phases (in frames) at which paced voice starts. Different phases put the 960-frame
    /// chunk boundaries in different places relative to the 1024-frame clock buffers.
    static let phases = [0, 1, 64, 250, 500, 700, 959, 960, 1000, 1023]

    @Test("Paced 960-frame voice against a 1024-frame clock plays without holes", arguments: phases)
    func pacedVoiceHasNoHoles(phase: Int) {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        // 50 chunks (1 s) delivered in real time, with no lead.
        let chunks = (0..<50).map { phase + $0 * 960 }
        let out = Self.mixPaced(mixer, voiceChunksAt: chunks, until: phase + 50 * 960 + 8 * 1024)
        // One unbroken run holding every voice sample: no zero-filled holes and nothing trimmed.
        #expect(Self.soundRuns(out) == [50 * 960 * 2])
    }

    @Test("A voice that runs dry builds its lead again before the next utterance", arguments: phases)
    func voiceReprimesAfterUnderrun(phase: Int) {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        let first = (0..<25).map { phase + $0 * 960 }
        // 10,000 frames (about 208 ms) of silence between the utterances.
        let secondStart = phase + 25 * 960 + 10_000
        let second = (0..<25).map { secondStart + $0 * 960 }
        let out = Self.mixPaced(mixer, voiceChunksAt: first + second, until: secondStart + 25 * 960 + 8 * 1024)
        #expect(Self.soundRuns(out) == [25 * 960 * 2, 25 * 960 * 2])
    }

    @Test("A sound shorter than the prefill plays once one prefill of clock frames has passed")
    func shortSoundPlaysAfterOnePrefill() {
        let mixer = AudioMixer()
        mixer.setClockSource("microphone")
        var out: [[Int16]] = []
        mixer.onMixedSample = { out.append(Self.samples($0)) }
        mixer.addSample(Self.buffer(frames: 1024, value: 0, pts: .zero), from: "microphone")
        // A 5 ms desktop-audio click, far below the 40 ms (1,920-frame) prefill.
        mixer.addSample(Self.buffer(frames: 240, value: 500, pts: .zero), from: "screen")
        for tick in 1...4 {
            mixer.addSample(Self.buffer(frames: 1024, value: 0, pts: CMTime(value: Int64(tick * 1024), timescale: 48000)),
                            from: "microphone")
        }
        // 1,024 clock frames after the click: still waiting. 2,048 >= 1,920: it plays, whole.
        #expect(out[1].allSatisfy { $0 == 0 })
        #expect(out[2].prefix(480).allSatisfy { $0 == 500 })
        #expect(out[2].dropFirst(480).allSatisfy { $0 == 0 })
        #expect(out[3].allSatisfy { $0 == 0 } && out[4].allSatisfy { $0 == 0 })
    }

    @Test("Ducking starts while the voice builds its lead, before the voice is audible")
    func duckingLeadsTheBufferedVoice() {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        mixer.voiceDuckAmount = 0.5
        mixer.voiceDuckHangover = 0   // only queued or playing voice can duck
        mixer.setClockSource("microphone")
        var out: [[Int16]] = []
        mixer.onMixedSample = { out.append(Self.samples($0)) }
        mixer.addSample(Self.buffer(frames: 1024, value: 100, pts: .zero), from: "microphone")
        mixer.addSample(Self.buffer(frames: 960, value: 1000, pts: .zero), from: "muse-voice")
        for tick in 1...3 {
            mixer.addSample(Self.buffer(frames: 1024, value: 100, pts: CMTime(value: Int64(tick * 1024), timescale: 48000)),
                            from: "microphone")
        }
        #expect(out[0].allSatisfy { $0 == 100 })
        #expect(out[1].allSatisfy { $0 == 50 })                      // voice queued but silent: mic ducked
        #expect(out[2].prefix(1920).allSatisfy { $0 == 1050 })       // voice plays over the ducked mic
        #expect(out[2].dropFirst(1920).allSatisfy { $0 == 50 })
        #expect(out[3].allSatisfy { $0 == 100 })                     // voice gone: duck released
    }

    @Test("Dropping a source's queue makes it build its lead again",
          arguments: ["deactivateSource", "unregisterSource", "setClockSource", "reset"])
    func droppingAQueueClearsItsLead(path: String) {
        let mixer = AudioMixer(voiceSourceID: "muse-voice")
        mixer.voiceDuckAmount = 1.0
        mixer.registerSource("microphone")
        mixer.registerSource("muse-voice")
        mixer.setClockSource("microphone")
        var out: [[Int16]] = []
        mixer.onMixedSample = { out.append(Self.samples($0)) }
        mixer.addSample(Self.buffer(frames: 1024, value: 0, pts: .zero), from: "microphone")
        // A full prefill of voice plays at the next tick and leaves 896 frames queued.
        mixer.addSample(Self.buffer(frames: 1920, value: 1000, pts: .zero), from: "muse-voice")
        mixer.addSample(Self.buffer(frames: 1024, value: 0, pts: .zero), from: "microphone")
        #expect(out[1].allSatisfy { $0 == 1000 })

        switch path {
        case "deactivateSource": mixer.deactivateSource("muse-voice")
        case "unregisterSource": mixer.unregisterSource("muse-voice")
        case "setClockSource":
            mixer.setClockSource("muse-voice")
            mixer.setClockSource("microphone")
        default:
            mixer.reset()
            mixer.setClockSource("microphone")
        }
        mixer.addSample(Self.buffer(frames: 960, value: 1000, pts: .zero), from: "muse-voice")
        mixer.addSample(Self.buffer(frames: 1024, value: 0, pts: .zero), from: "microphone")
        // Not still primed: a lone chunk waits for its lead instead of playing with a hole after it.
        #expect(out.last?.allSatisfy { $0 == 0 } == true)
    }

    @Test("The prefill defaults to 40 ms and stays at most half the queue cap")
    func prefillIsBoundedBelowTheCap() {
        #expect(AudioMixer().prefillSeconds == 0.04)
        #expect(AudioMixer(prefillSeconds: 1).prefillSeconds == AudioMixer().maxQueuedSeconds / 2)
        #expect(AudioMixer(prefillSeconds: -1).prefillSeconds == 0)
    }

    /// Feeds a silent 1024-frame microphone clock and 960-frame voice chunks (value 1000)
    /// through `mixer` in time order, as the router delivers them in real time. A chunk due at
    /// the same frame as a clock buffer is delivered first. Returns the mixed samples.
    static func mixPaced(_ mixer: AudioMixer, voiceChunksAt chunkTimes: [Int], until end: Int) -> [Int16] {
        var out: [Int16] = []
        mixer.onMixedSample = { out.append(contentsOf: Self.samples($0)) }
        mixer.setClockSource("microphone")
        var pending = chunkTimes.sorted()[...]
        var tick = 1024
        while tick <= end {
            while let due = pending.first, due <= tick {
                mixer.addSample(Self.buffer(frames: 960, value: 1000, pts: .zero), from: "muse-voice")
                pending = pending.dropFirst()
            }
            mixer.addSample(Self.buffer(frames: 1024, value: 0, pts: CMTime(value: Int64(tick - 1024), timescale: 48000)),
                            from: "microphone")
            tick += 1024
        }
        return out
    }

    /// Lengths, in samples, of the runs of non-zero samples, in order.
    static func soundRuns(_ samples: [Int16]) -> [Int] {
        var runs: [Int] = []
        var current = 0
        for sample in samples {
            if sample != 0 {
                current += 1
            } else if current > 0 {
                runs.append(current)
                current = 0
            }
        }
        if current > 0 { runs.append(current) }
        return runs
    }
}
