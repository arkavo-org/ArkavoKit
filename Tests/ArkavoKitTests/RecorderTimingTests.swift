import Testing
import AVFoundation
import CoreMedia
import CoreVideo
@testable import ArkavoRecorder

/// Timing the encoder gives what it writes (#44)
struct RecorderTimingTests {
    @Test("A retimed audio buffer keeps its samples and its 20 ms duration")
    func retimedAudioKeepsItsDuration() throws {
        let original = AudioMixerTests.buffer(frames: 960, value: 1000, pts: CMTime(value: 96000, timescale: 48000))
        let retimed = try #require(VideoEncoder.retimed(original, to: CMTime(value: 48000, timescale: 48000)))

        #expect(CMSampleBufferGetNumSamples(retimed) == 960)
        #expect(CMSampleBufferGetPresentationTimeStamp(retimed) == CMTime(value: 48000, timescale: 48000))
        #expect(abs(CMSampleBufferGetDuration(retimed).seconds - 0.02) < 1e-9,
                "duration \(CMSampleBufferGetDuration(retimed).seconds)")
    }

    @Test("A recording keeps its first video frame")
    func firstVideoFrameIsKept() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-frame-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let frames = 10
        let encoder = VideoEncoder(quality: .performance)
        try await encoder.startRecording(to: url, title: "first", audioSourceIDs: [], videoEnabled: true)
        for i in 0..<frames {
            await encoder.encodeVideoFrame(try DroppedMediaTests.pixelBuffer(), timestamp: CMTime(value: CMTimeValue(i * 1600), timescale: 48000))
            try await Task.sleep(for: .milliseconds(34))
        }
        _ = try await encoder.finishRecording()

        let dropped = await encoder.droppedMedia.video
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var written = 0
        while let buffer = output.copyNextSampleBuffer() {
            written += CMSampleBufferGetNumSamples(buffer)
        }
        #expect(written + dropped.total == frames, "wrote \(written), dropped \(dropped)")
        #expect(dropped.outOfOrder == 0, "\(dropped)")
    }
}
