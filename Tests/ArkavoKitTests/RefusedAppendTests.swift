import Testing
import AVFoundation
import CoreMedia
import CoreVideo
@testable import ArkavoRecorder

/// The writer says whether it takes a buffer only when the buffer is appended, after the encoder
/// has worked out where it goes on the file's timeline. A buffer the file doesn't take leaves that
/// timeline as it was: it doesn't set the file's start (#44), and it doesn't use up a pause's gap.
///
/// Each check holds however many more buffers the real writer refuses: the counters rely on
/// follow-ups stamped before the refused buffer, and positions are measured from what was written.
struct RefusedAppendTests {
    @Test("A first video frame the writer isn't ready for doesn't set the file's start")
    func refusedFirstVideoFrameDoesNotSetTheStart() async throws {
        let url = Self.url("mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder(quality: .performance)
        try await encoder.startRecording(to: url, title: "refused", audioSourceIDs: ["microphone"], videoEnabled: true)
        await encoder.refuseAppendsForTesting([.notReady])
        try await Self.feedFrames(encoder, at: [48000])
        // No start yet, so audio waits for the first frame the file takes
        await encoder.encodeAudioSample(AudioMixerTests.buffer(frames: 960, value: 1000, pts: CMTime(value: 48800, timescale: 48000)),
                                        sourceID: "microphone")
        // Stamped before the refused frame: with its stale start they'd all be before the start
        try await Self.feedFrames(encoder, at: (0..<9).map { 24000 + $0 * 1600 })
        _ = try? await encoder.finishRecording()

        let dropped = await encoder.droppedMedia
        #expect(dropped.video.notReady >= 1, "\(dropped)")
        #expect(dropped.video.beforeStart == 0, "\(dropped)")
        #expect(dropped.audio.beforeSession == 1, "\(dropped)")
        #expect(try await Self.videoSampleTimes(url).first == .zero)
    }

    @Test("A first audio-only sample the writer isn't ready for doesn't set the file's start")
    func refusedFirstAudioSampleDoesNotSetTheStart() async throws {
        let url = Self.url("m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "refused", audioSourceIDs: ["microphone"], videoEnabled: false)
        await encoder.refuseAppendsForTesting([.notReady])
        try await Self.feedAudio(encoder, at: [48000] + (0..<9).map { 24000 + $0 * 960 })
        _ = try? await encoder.finishRecording()

        let dropped = await encoder.droppedMedia.audio
        #expect(dropped.notReady >= 1, "\(dropped)")
        #expect(dropped.beforeStart == 0, "\(dropped)")
        #expect(try await DroppedMediaTests.audioBufferTimes(url).first?.pts == .zero)
    }

    @Test("A first video frame the writer fails on doesn't set the file's start")
    func failedFirstVideoFrameDoesNotSetTheStart() async throws {
        let url = Self.url("mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder(quality: .performance)
        try await encoder.startRecording(to: url, title: "failed", audioSourceIDs: [], videoEnabled: true)
        await encoder.refuseAppendsForTesting([.failed])
        try await Self.feedFrames(encoder, at: [48000] + (0..<9).map { 24000 + $0 * 1600 })
        _ = try? await encoder.finishRecording()

        let dropped = await encoder.droppedMedia.video
        #expect(dropped.rejected == 1, "\(dropped)")
        #expect(dropped.beforeStart == 0, "\(dropped)")
        #expect(try await Self.videoSampleTimes(url).first == .zero)
    }

    @Test("A first frame after a resume that the writer isn't ready for leaves no gap")
    func refusedFirstFrameAfterAResumeLeavesNoGap() async throws {
        try await Self.checkResumeLeavesNoGap { encoder in
            await encoder.refuseAppendsForTesting([.notReady])
        }
    }

    @Test("A late duplicate frame right after a resume leaves no gap")
    func lateDuplicateAfterAResumeLeavesNoGap() async throws {
        let dropped = try await Self.checkResumeLeavesNoGap { encoder in
            // The last frame before the pause, delivered again: out of order
            try await Self.feedFrames(encoder, at: [48000 + 4 * 1600])
        }
        #expect(dropped.notReady > 0 || dropped.outOfOrder == 1, "\(dropped)")
    }

    @Test("A recording whose every sample is refused is empty, and its file is removed")
    func aRecordingWhoseEverySampleIsRefusedIsEmpty() async throws {
        let url = Self.url("m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "refused", audioSourceIDs: ["microphone"], videoEnabled: false)
        await encoder.refuseAppendsForTesting(Array(repeating: .notReady, count: 5))
        try await Self.feedAudio(encoder, at: (0..<5).map { 48000 + $0 * 960 })

        do {
            _ = try await encoder.finishRecording()
            Issue.record("expected RecorderError.noMediaWritten")
        } catch RecorderError.noMediaWritten {
        } catch {
            Issue.record("expected RecorderError.noMediaWritten, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Helpers

    /// Five frames, a pause, then `afterResume` and five frames stamped 2 s later. The first frame
    /// written after the resume follows the last one written before it, whichever frames the
    /// writer itself refused. Returns what the recording dropped.
    @discardableResult
    static func checkResumeLeavesNoGap(afterResume: (VideoEncoder) async throws -> Void) async throws -> DroppedMedia.Counts {
        let url = Self.url("mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder(quality: .performance)
        try await encoder.startRecording(to: url, title: "resume", audioSourceIDs: [], videoEnabled: true)
        try await Self.feedFrames(encoder, at: (0..<5).map { 48000 + $0 * 1600 })
        let before = 5 - (await encoder.droppedMedia.video.total)
        try #require(before > 0)
        await encoder.pause()
        await encoder.resume()
        try await afterResume(encoder)
        try await Self.feedFrames(encoder, at: (0..<5).map { 144000 + $0 * 1600 })
        _ = try? await encoder.finishRecording()

        let dropped = await encoder.droppedMedia.video
        let times = try await Self.videoSampleTimes(url)
        try #require(times.count > before, "\(times) \(dropped)")
        #expect(times[before] == CMTimeAdd(times[before - 1], CMTime(value: 1600, timescale: 48000)), "\(times) \(dropped)")
        return dropped
    }

    /// One frame per time (timescale 48000), 34 ms apart, as a 30 fps capture delivers them
    static func feedFrames(_ encoder: VideoEncoder, at times: [Int]) async throws {
        for time in times {
            await encoder.encodeVideoFrame(try DroppedMediaTests.pixelBuffer(), timestamp: CMTime(value: CMTimeValue(time), timescale: 48000))
            try await Task.sleep(for: .milliseconds(34))
        }
    }

    /// One 960-frame buffer per time (timescale 48000), 20 ms apart, as capture delivers them
    static func feedAudio(_ encoder: VideoEncoder, at times: [Int]) async throws {
        for time in times {
            let pts = CMTime(value: CMTimeValue(time), timescale: 48000)
            await encoder.encodeAudioSample(AudioMixerTests.buffer(frames: 960, value: 1000, pts: pts), sourceID: "microphone")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Presentation times of the file's video samples, as stored, in file order
    static func videoSampleTimes(_ url: URL) async throws -> [CMTime] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let buffers = reader.outputProvider(for: output)
        try reader.start()
        var times: [CMTime] = []
        while let buffer = try await buffers.next() {
            guard buffer.sampleCount > 0 else { continue }
            times.append(buffer.presentationTimeStamp)
        }
        return times
    }

    static func url(_ fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(UUID().uuidString).\(fileExtension)")
    }
}
