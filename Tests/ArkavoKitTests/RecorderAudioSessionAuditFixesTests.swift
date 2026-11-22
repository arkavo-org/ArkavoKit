import AVFoundation
import CoreMedia
import Foundation
import os
import Testing
@testable import ArkavoRecorder

struct RecorderAudioSessionAuditFixesTests {
    // MARK: - C11: NDJSONFramer O(N) performance on 100KB of newlines

    @Test("NDJSONFramer handles 100KB of newlines in linear time")
    func ndjsonFramerLinearTimeOn100KBNewlines() throws {
        var framer = NDJSONFramer(maxMessageSize: RemoteCameraConstants.maxMessageSize)
        let payload = Data(repeating: 0x0A, count: 100_000)

        let start = ContinuousClock.now
        let messages = try framer.append(payload)
        let elapsed = start.duration(to: .now)

        #expect(messages.count == 100_000)
        #expect(messages.allSatisfy { $0.isEmpty })
        #expect(elapsed < .seconds(2), "Expected O(N) framing under 2s, took \(elapsed)")
    }

    // MARK: - M6: AudioFormatConverter planar Int16 conversion (not bypassed)

    @Test("AudioFormatConverter converts planar Int16 stereo into interleaved Int16 instead of bypassing")
    func audioFormatConverterDoesNotBypassPlanarInt16() throws {
        let frames = 480
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(pcm.int16ChannelData)
        for i in 0..<frames {
            channels[0][i] = 1234
            channels[1][i] = -5678
        }

        var formatDescription: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr)

        var inputBuffer: CMSampleBuffer?
        #expect(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: try #require(formatDescription),
            sampleCount: frames,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &inputBuffer
        ) == noErr)
        let input = try #require(inputBuffer)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(
            input,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        ) == noErr)

        let converter = AudioFormatConverter(targetSampleRate: 48_000, targetChannels: 2, sourceID: "planar-int16")
        let output = try #require(converter.convert(input))
        let outDesc = try #require(CMSampleBufferGetFormatDescription(output))
        let outASBD = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(outDesc)?.pointee)

        // Output must be interleaved (kAudioFormatFlagIsNonInterleaved cleared)
        #expect((outASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0)
        #expect(CMSampleBufferGetNumSamples(output) == frames)

        let samples = try Self.extractInt16Samples(from: output)
        #expect(samples.count == frames * 2)
        for i in 0..<frames {
            #expect(samples[i * 2] == 1234)
            #expect(samples[i * 2 + 1] == -5678)
        }
    }

    // MARK: - C6: AudioMixer non-contiguous CMBlockBuffer

    @Test("AudioMixer reads all segments of a non-contiguous CMBlockBuffer without over-reading")
    func audioMixerHandlesNonContiguousBlockBuffer() throws {
        let firstHalfFrames = 240
        let secondHalfFrames = 240
        let totalFrames = firstHalfFrames + secondHalfFrames
        let seg1Samples = [Int16](repeating: 1111, count: firstHalfFrames * 2)
        let seg2Samples = [Int16](repeating: 2222, count: secondHalfFrames * 2)

        let nonContiguousBlock = try Self.makeNonContiguousBlockBuffer(segments: [seg1Samples, seg2Samples])
        let totalBytes = (seg1Samples.count + seg2Samples.count) * MemoryLayout<Int16>.size
        #expect(!CMBlockBufferIsRangeContiguous(nonContiguousBlock, atOffset: 0, length: totalBytes))

        let sb = try Self.makeInterleavedInt16SampleBuffer(
            blockBuffer: nonContiguousBlock,
            frameCount: totalFrames,
            sampleRate: 48_000,
            channels: 2,
            pts: .zero
        )

        let mixer = AudioMixer(sampleRate: 48_000, channels: 2, prefillSeconds: 0)
        var emitted: [CMSampleBuffer] = []
        mixer.onMixedSample = { emitted.append($0) }
        mixer.addSample(sb, from: "microphone")

        #expect(emitted.count == 1)
        let outSamples = try Self.extractInt16Samples(from: try #require(emitted.first))
        #expect(outSamples.count == totalFrames * 2)
        #expect(outSamples.prefix(firstHalfFrames * 2).allSatisfy { $0 == 1111 })
        #expect(outSamples.suffix(secondHalfFrames * 2).allSatisfy { $0 == 2222 })
    }

    // MARK: - C8: RemoteCameraAudioSource rejects malicious payloads without trapping

    @Test("RemoteCameraAudioSource rejects malicious channel counts, bad sample rates, and empty audio safely")
    func remoteCameraAudioSourceRejectsMaliciousPayloads() async throws {
        let source = RemoteCameraAudioSource(sourceID: "remote-1", sourceName: "Remote Test")
        try await source.start()

        let received = OSAllocatedUnfairLock(initialState: 0)
        source.onSample = { _ in
            received.withLock { $0 += 1 }
        }

        let pcmBytes = Data(repeating: 0x01, count: 64)
        let maliciousPayloads: [RemoteCameraMessage.AudioPayload] = [
            RemoteCameraMessage.AudioPayload(sourceID: "remote-1", timestamp: 1.0, sampleRate: 48_000, channels: 0, audioData: pcmBytes),
            RemoteCameraMessage.AudioPayload(sourceID: "remote-1", timestamp: 1.0, sampleRate: 48_000, channels: -1, audioData: pcmBytes),
            RemoteCameraMessage.AudioPayload(sourceID: "remote-1", timestamp: 1.0, sampleRate: 48_000, channels: Int.max, audioData: pcmBytes),
            RemoteCameraMessage.AudioPayload(sourceID: "remote-1", timestamp: 1.0, sampleRate: 48_000, channels: Int.min, audioData: pcmBytes),
            RemoteCameraMessage.AudioPayload(sourceID: "remote-1", timestamp: 1.0, sampleRate: 48_000, channels: 9, audioData: pcmBytes),
            RemoteCameraMessage.AudioPayload(sourceID: "remote-1", timestamp: 1.0, sampleRate: 0, channels: 2, audioData: pcmBytes),
            RemoteCameraMessage.AudioPayload(sourceID: "remote-1", timestamp: 1.0, sampleRate: .nan, channels: 2, audioData: pcmBytes),
            RemoteCameraMessage.AudioPayload(sourceID: "remote-1", timestamp: 1.0, sampleRate: .infinity, channels: 2, audioData: pcmBytes),
            RemoteCameraMessage.AudioPayload(sourceID: "remote-1", timestamp: .nan, sampleRate: 48_000, channels: 2, audioData: pcmBytes),
            RemoteCameraMessage.AudioPayload(sourceID: "remote-1", timestamp: 1.0, sampleRate: 48_000, channels: 2, audioData: Data()),
        ]

        for payload in maliciousPayloads {
            source.processAudioPayload(payload)
        }
        #expect(received.withLock { $0 } == 0)

        // Valid stereo payload must still succeed
        let validPayload = RemoteCameraMessage.AudioPayload(
            sourceID: "remote-1",
            timestamp: 1.5,
            sampleRate: 48_000,
            channels: 2,
            audioData: pcmBytes
        )
        source.processAudioPayload(validPayload)
        #expect(received.withLock { $0 } == 1)
    }

    // MARK: - M9 & C6: AudioManager & MicrophoneAudioSource 0-byte, Float32, and non-contiguous level

    @Test("AudioManager and MicrophoneAudioSource return 0.0 (not 1.0/NaN) on 0-byte audio buffers")
    func zeroByteAudioLevelReturnsZero() throws {
        var emptyBlock: CMBlockBuffer?
        #expect(CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: 0,
            flags: 0,
            blockBufferOut: &emptyBlock
        ) == kCMBlockBufferNoErr)

        let sb = try Self.makeInterleavedInt16SampleBuffer(
            blockBuffer: try #require(emptyBlock),
            frameCount: 0,
            sampleRate: 48_000,
            channels: 2,
            pts: .zero
        )

        #expect(AudioManager.calculateAudioLevel(from: sb) == 0.0)
        #expect(MicrophoneAudioSource.calculateAudioLevel(from: sb) == 0.0)
    }

    @Test("AudioManager and MicrophoneAudioSource compute level for Float32 PCM and non-contiguous buffers")
    func audioLevelHandlesFloat32AndNonContiguousBuffers() throws {
        // Float32 buffer at amplitude 0.05 -> RMS = 0.05 -> scaled * 10 = 0.5
        let frames = 256
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var desc: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &desc
        ) == noErr)

        let floatSamples = [Float](repeating: 0.05, count: frames)
        let byteCount = frames * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr)
        let unwrappedBlock = try #require(block)
        let replaceStatus = floatSamples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: unwrappedBlock,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        #expect(replaceStatus == kCMBlockBufferNoErr)

        var sb: CMSampleBuffer?
        #expect(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: unwrappedBlock,
            formatDescription: try #require(desc),
            sampleCount: frames,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sb
        ) == noErr)
        let floatBuffer = try #require(sb)

        let managerLevel = AudioManager.calculateAudioLevel(from: floatBuffer)
        let micLevel = MicrophoneAudioSource.calculateAudioLevel(from: floatBuffer)
        #expect(abs(managerLevel - 0.5) < 0.01)
        #expect(abs(micLevel - 0.5) < 0.01)

        // Non-contiguous Int16 buffer: first half 0, second half ~1638 (~0.05 full scale)
        let seg1 = [Int16](repeating: 0, count: 256)
        let seg2 = [Int16](repeating: 1638, count: 256)
        let nonContig = try Self.makeNonContiguousBlockBuffer(segments: [seg1, seg2])
        let nonContigSB = try Self.makeInterleavedInt16SampleBuffer(
            blockBuffer: nonContig,
            frameCount: 256,
            sampleRate: 48_000,
            channels: 2,
            pts: .zero
        )
        let nonContigLevel = AudioManager.calculateAudioLevel(from: nonContigSB)
        #expect(nonContigLevel > 0.2 && nonContigLevel < 0.5)
    }

    // MARK: - #51: AudioRouter stale-removal protection

    @Test("AudioRouter.stopAndRemoveSource does not remove a replacement source added while stopping")
    func audioRouterProtectsReplacementFromStaleRemoval() async throws {
        let router = AudioRouter()
        let first = SuspendedStopAudioSource(sourceID: "microphone")
        let replacement = SimpleAudioSource(sourceID: "microphone")
        router.addSource(first)
        try await router.startAll()

        let routedCount = OSAllocatedUnfairLock(initialState: 0)
        router.onConvertedSample = { _, _ in
            routedCount.withLock { $0 += 1 }
        }

        // Begin stopAndRemoveSource on `first`; it suspends inside `first.stop()`
        let stopTask = Task {
            await router.stopAndRemoveSource("microphone")
        }
        try await first.waitUntilStopEntered()

        // Replace `"microphone"` while `first` is still stopping
        router.addSource(replacement)

        // Release `first.stop()` and wait for `stopAndRemoveSource` to finish
        first.releaseStop()
        await stopTask.value

        // `replacement` must still be registered and actively routing samples
        #expect(router.allSourceIDs.contains("microphone"))
        let sample = AudioMixerTests.buffer(frames: 480, value: 500, pts: .zero)
        replacement.onSample?(sample)
        #expect(routedCount.withLock { $0 } == 1)

        // Stale sample delivered from `first` must be ignored
        first.deliverStaleSample(sample)
        #expect(routedCount.withLock { $0 } == 1)
    }

    // MARK: - #52 & Kimi omission: MuseTTSAudioSource default ID, planar copy, host-clock PTS

    @Test("MuseTTSAudioSource defaults to muse-voice, preserves planar channels, and uses host-clock PTS")
    func museTTSDefaultsPlanarAndHostClockPTS() throws {
        let source = MuseTTSAudioSource()
        #expect(source.sourceID == "muse-voice")

        let frames = 480
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(pcm.floatChannelData)
        for i in 0..<frames {
            channels[0][i] = 0.25
            channels[1][i] = -0.5
        }

        let before = CMClockGetTime(CMClockGetHostTimeClock())
        let sb1 = try #require(source.convertToSampleBuffer(pcm))
        let sb2 = try #require(source.convertToSampleBuffer(pcm))
        let after = CMClockGetTime(CMClockGetHostTimeClock())

        let pts1 = CMSampleBufferGetPresentationTimeStamp(sb1)
        let pts2 = CMSampleBufferGetPresentationTimeStamp(sb2)
        #expect(pts1.seconds >= before.seconds - 0.05)
        #expect(pts1.seconds <= after.seconds + 0.05)
        #expect(abs((pts2.seconds - pts1.seconds) - (Double(frames) / 48_000.0)) < 0.001)

        // Verify both planar channels are preserved when converted through AudioFormatConverter
        let converter = AudioFormatConverter(targetSampleRate: 48_000, targetChannels: 2, sourceID: "muse-voice")
        let converted = try #require(converter.convert(sb1))
        let outSamples = try Self.extractInt16Samples(from: converted)
        #expect(outSamples.count == frames * 2)
        #expect(abs(Int(outSamples[0]) - 8192) <= 2)
        #expect(abs(Int(outSamples[1]) + 16384) <= 2)
    }

    // MARK: - Helpers

    private static func makeNonContiguousBlockBuffer(segments: [[Int16]]) throws -> CMBlockBuffer {
        var combined: CMBlockBuffer?
        #expect(CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: UInt32(segments.count),
            flags: 0,
            blockBufferOut: &combined
        ) == kCMBlockBufferNoErr)
        let root = try #require(combined)

        for segment in segments {
            let byteLength = segment.count * MemoryLayout<Int16>.size
            var segBlock: CMBlockBuffer?
            #expect(CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteLength,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteLength,
                flags: 0,
                blockBufferOut: &segBlock
            ) == kCMBlockBufferNoErr)
            let unwrappedSeg = try #require(segBlock)
            let replaceStatus = segment.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!,
                    blockBuffer: unwrappedSeg,
                    offsetIntoDestination: 0,
                    dataLength: byteLength
                )
            }
            #expect(replaceStatus == kCMBlockBufferNoErr)
            #expect(CMBlockBufferAppendBufferReference(
                root,
                targetBBuf: unwrappedSeg,
                offsetToData: 0,
                dataLength: byteLength,
                flags: 0
            ) == kCMBlockBufferNoErr)
        }
        return root
    }

    private static func makeInterleavedInt16SampleBuffer(
        blockBuffer: CMBlockBuffer,
        frameCount: Int,
        sampleRate: Double,
        channels: UInt32,
        pts: CMTime
    ) throws -> CMSampleBuffer {
        let bytesPerFrame = channels * 2
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var desc: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &desc
        ) == noErr)

        let formatDesc = try #require(desc)
        var sb: CMSampleBuffer?
        if frameCount == 0 {
            #expect(CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDesc,
                sampleCount: 0,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sb
            ) == noErr)
        } else {
            #expect(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDesc,
                sampleCount: frameCount,
                presentationTimeStamp: pts,
                packetDescriptions: nil,
                sampleBufferOut: &sb
            ) == noErr)
        }
        return try #require(sb)
    }

    private static func extractInt16Samples(from sb: CMSampleBuffer) throws -> [Int16] {
        let block = try #require(CMSampleBufferGetDataBuffer(sb))
        let byteLength = CMBlockBufferGetDataLength(block)
        let count = byteLength / MemoryLayout<Int16>.size
        var samples = [Int16](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes { dest in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: dest.baseAddress!)
        }
        #expect(status == kCMBlockBufferNoErr)
        return samples
    }
}

private final class SimpleAudioSource: AudioSource, @unchecked Sendable {
    let sourceID: String
    let sourceName = "Simple"
    let format = AudioFormat(sampleRate: 48_000, channels: 2, bitDepth: 16, formatID: kAudioFormatLinearPCM)
    private let state = OSAllocatedUnfairLock<(active: Bool, onSample: ((CMSampleBuffer) -> Void)?)>(uncheckedState: (false, nil))

    var isActive: Bool { state.withLockUnchecked { $0.active } }
    var onSample: ((CMSampleBuffer) -> Void)? {
        get { state.withLockUnchecked { $0.onSample } }
        set { state.withLockUnchecked { $0.onSample = newValue } }
    }

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func start() async throws {
        state.withLockUnchecked { $0.active = true }
    }

    func stop() async throws {
        state.withLockUnchecked { $0.active = false }
    }
}

private final class SuspendedStopAudioSource: AudioSource, @unchecked Sendable {
    let sourceID: String
    let sourceName = "SuspendedStop"
    let format = AudioFormat(sampleRate: 48_000, channels: 2, bitDepth: 16, formatID: kAudioFormatLinearPCM)

    private struct State {
        var active = false
        var onSample: ((CMSampleBuffer) -> Void)?
        var lastOnSample: ((CMSampleBuffer) -> Void)?
        var stopEntered = false
        var releaseStop = false
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    var isActive: Bool { state.withLockUnchecked { $0.active } }
    var onSample: ((CMSampleBuffer) -> Void)? {
        get { state.withLockUnchecked { $0.onSample } }
        set {
            state.withLockUnchecked { state in
                state.onSample = newValue
                if let newValue { state.lastOnSample = newValue }
            }
        }
    }

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func start() async throws {
        state.withLockUnchecked { $0.active = true }
    }

    func stop() async throws {
        state.withLockUnchecked { $0.stopEntered = true }
        while !state.withLockUnchecked({ $0.releaseStop }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        state.withLockUnchecked { $0.active = false }
    }

    func waitUntilStopEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !state.withLockUnchecked({ $0.stopEntered }) && .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(state.withLockUnchecked { $0.stopEntered })
    }

    func releaseStop() {
        state.withLockUnchecked { $0.releaseStop = true }
    }

    func deliverStaleSample(_ sampleBuffer: CMSampleBuffer) {
        let stale = state.withLockUnchecked { $0.lastOnSample }
        stale?(sampleBuffer)
    }
}
