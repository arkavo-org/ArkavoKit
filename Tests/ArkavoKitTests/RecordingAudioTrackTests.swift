import Testing
import AVFoundation
import CoreMedia
@testable import ArkavoRecorder

/// Every audio source reaches the file through the mixer, so the encoder must hold
/// one input keyed by the mixer's output ID. An input per router source receives nothing.
struct RecordingAudioTrackTests {
    @Test("The encoder gets the mixer's output track whenever any audio source is registered")
    func trackIDsFollowTheMixer() {
        #expect(RecordingSession.encoderAudioTrackIDs(forRouterSources: []) == [])
        #expect(RecordingSession.encoderAudioTrackIDs(forRouterSources: ["microphone"]) == [AudioMixer.outputSourceID])
        #expect(RecordingSession.encoderAudioTrackIDs(forRouterSources: ["microphone", "screen", "muse-voice"])
            == [AudioMixer.outputSourceID])
    }

    @Test("An audio-only recording of mixer output writes a non-empty audio track")
    func audioOnlyRecordingKeepsMixedAudio() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder()
        try await encoder.startRecording(
            to: url, title: "mixed",
            audioSourceIDs: RecordingSession.encoderAudioTrackIDs(forRouterSources: ["microphone"]),
            videoEnabled: false
        )
        for i in 0..<50 {  // 1 s of 20 ms buffers, as the mixer emits them on the mic's clock
            let pts = CMTime(value: CMTimeValue(i * 960), timescale: 48000)
            let sample = AudioMixerTests.buffer(frames: 960, value: 1000, pts: pts)
            await encoder.encodeAudioSample(sample, sourceID: AudioMixer.outputSourceID)
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = try await encoder.finishRecording()

        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size > 0)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(duration > 0.5)
    }
}
