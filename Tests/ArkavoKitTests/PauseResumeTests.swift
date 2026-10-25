import Testing
import AVFoundation
import CoreMedia
import CoreVideo
@testable import ArkavoRecorder

/// A pause leaves no gap: the media after `resume()` continues where the media before
/// `pause()` ended, on every track.
struct PauseResumeTests {
    @Test("An audio-only recording paused for 1 s is 2 s long, not 3 s")
    func audioOnlyPauseLeavesNoGap() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "pause", audioSourceIDs: ["microphone"], videoEnabled: false)
        try await Self.feedAudio(encoder, from: 0, seconds: 1)
        await encoder.pause()
        try await Self.feedAudio(encoder, from: 1, seconds: 1)  // captured while paused: dropped
        await encoder.resume()
        try await Self.feedAudio(encoder, from: 2, seconds: 1)
        _ = try await encoder.finishRecording()

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.05, "duration \(duration)")
    }

    @Test("A paused video recording keeps audio and video on one timeline without the gap")
    func videoPauseLeavesNoGapOnEitherTrack() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-video-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder(quality: .performance)
        try await encoder.startRecording(to: url, title: "pause", audioSourceIDs: ["microphone"], videoEnabled: true)
        try await Self.feedAudioAndVideo(encoder, from: 0, seconds: 1)
        await encoder.pause()
        try await Self.feedAudioAndVideo(encoder, from: 1, seconds: 1)  // dropped
        await encoder.resume()
        try await Self.feedAudioAndVideo(encoder, from: 2, seconds: 1)
        _ = try await encoder.finishRecording()

        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let videoEnd = try await video.load(.timeRange).end.seconds
        let audioEnd = try await audio.load(.timeRange).end.seconds
        #expect(abs(videoEnd - 2) < 0.1, "video ends at \(videoEnd)")
        #expect(abs(audioEnd - 2) < 0.1, "audio ends at \(audioEnd)")
    }

    // MARK: - Helpers

    /// 20 ms buffers of 48 kHz stereo PCM covering `seconds` from `from`
    private static func feedAudio(_ encoder: VideoEncoder, from start: Int, seconds: Int) async throws {
        for i in 0..<(50 * seconds) {
            let pts = CMTime(value: CMTimeValue(start * 48000 + i * 960), timescale: 48000)
            await encoder.encodeAudioSample(AudioMixerTests.buffer(frames: 960, value: 1000, pts: pts), sourceID: "microphone")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// 30 fps video and 20 ms audio buffers covering `seconds` from `from`, in time order,
    /// starting with a video frame
    private static func feedAudioAndVideo(_ encoder: VideoEncoder, from start: Int, seconds: Int) async throws {
        let base = CMTimeValue(start * 48000)
        let video = (0..<(30 * seconds)).map { (time: base + CMTimeValue($0 * 1600), isVideo: true) }
        let audio = (0..<(50 * seconds)).map { (time: base + CMTimeValue($0 * 960), isVideo: false) }
        let events = (video + audio).sorted { ($0.time, $0.isVideo ? 0 : 1) < ($1.time, $1.isVideo ? 0 : 1) }
        for event in events {
            let pts = CMTime(value: event.time, timescale: 48000)
            if event.isVideo {
                await encoder.encodeVideoFrame(try pixelBuffer(width: 1280, height: 720), timestamp: pts)
            } else {
                await encoder.encodeAudioSample(AudioMixerTests.buffer(frames: 960, value: 1000, pts: pts), sourceID: "microphone")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw RecorderError.encodingFailed }
        return buffer
    }
}
