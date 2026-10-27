import Testing
import AVFoundation
import CoreMedia
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
        #expect(abs(written + (dropped.notReady + dropped.rejected) * 960 - fed * 960) <= 2112,
                "decoded \(written) frames, dropped \(dropped)")
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
