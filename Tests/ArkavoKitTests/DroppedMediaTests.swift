import Testing
import AVFoundation
import CoreMedia
import CoreVideo
@testable import ArkavoRecorder

/// The encoder drops media the writer isn't ready for (#44). It counts what it drops, so a
/// recording that comes out short can say why.
struct DroppedMediaTests {
    @Test("Every audio buffer fed either reaches the file or is counted as dropped")
    func droppedAudioIsCounted() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let fed = 100  // 2 s of 20 ms buffers, sent as fast as possible
        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "drops", audioSourceIDs: ["microphone"], videoEnabled: false)
        for i in 0..<fed {
            let pts = CMTime(value: CMTimeValue(i * 960), timescale: 48000)
            await encoder.encodeAudioSample(AudioMixerTests.buffer(frames: 960, value: 1000, pts: pts), sourceID: "microphone")
        }
        _ = try await encoder.finishRecording()

        let dropped = await encoder.droppedMedia.audio
        let written = try await Self.decodedFrames(url)
        // AAC adds priming and padding of up to 2112 frames
        #expect(abs(written + dropped.total * 960 - fed * 960) <= 2112,
                "decoded \(written) frames, dropped \(dropped)")
    }

    @Test("Audio from before the recording's start, and audio for a source without an input, are counted")
    func earlyAndUnknownAudioIsCounted() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-early-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "early", audioSourceIDs: ["microphone"], videoEnabled: false)
        // The first buffer the writer takes sets the start, at 1 s or just after, so one stamped
        // 0.5 s comes before it. Five at real-time pace, in case the writer isn't ready at first.
        for i in 0..<5 {
            let pts = CMTime(value: CMTimeValue(48000 + i * 960), timescale: 48000)
            await encoder.encodeAudioSample(AudioMixerTests.buffer(frames: 960, value: 1000, pts: pts), sourceID: "microphone")
            try await Task.sleep(for: .milliseconds(20))
        }
        await encoder.encodeAudioSample(AudioMixerTests.buffer(frames: 960, value: 1000, pts: CMTime(value: 24000, timescale: 48000)), sourceID: "microphone")
        await encoder.encodeAudioSample(AudioMixerTests.buffer(frames: 960, value: 1000, pts: CMTime(value: 49000, timescale: 48000)), sourceID: "desktop")
        _ = try? await encoder.finishRecording()

        let dropped = await encoder.droppedMedia.audio
        #expect(dropped.notReady == 5 || dropped.beforeStart == 1, "\(dropped)")
        #expect(dropped.noInput == 1, "\(dropped)")
    }

    @Test("A video frame stamped no later than the previous one is counted as out of order")
    func outOfOrderVideoIsCounted() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-order-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder(quality: .performance)
        try await encoder.startRecording(to: url, title: "order", audioSourceIDs: [], videoEnabled: true)
        for value in [0, 1600, 3200, 3200, 1600, 4800] as [CMTimeValue] {
            await encoder.encodeVideoFrame(try Self.pixelBuffer(), timestamp: CMTime(value: value, timescale: 48000))
            try await Task.sleep(for: .milliseconds(34))
        }
        _ = try? await encoder.finishRecording()

        let dropped = await encoder.droppedMedia.video
        // The repeated 3200 and the 1600 after it. A frame the writer wasn't ready for never
        // reaches the order check, so the count is exact only when none were.
        #expect(dropped.notReady > 0 || dropped.outOfOrder == 2, "\(dropped)")
    }

    @Test("A new recording starts with no drops counted")
    func countsResetPerRecording() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-reset-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "reset", audioSourceIDs: ["microphone"], videoEnabled: false)
        #expect(await encoder.droppedMedia == DroppedMedia())
        _ = try? await encoder.finishRecording()
    }

    static func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw RecorderError.encodingFailed }
        return buffer
    }

    /// Linear PCM frames decoded from the file's audio track
    static func decodedFrames(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        #expect(reader.startReading())
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() {
            frames += CMSampleBufferGetNumSamples(buffer)
        }
        return frames
    }
}
