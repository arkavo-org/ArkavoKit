import Testing
import AVFoundation
import CoreMedia
@testable import ArkavoRecorder

/// A recording that no audio or video reached must fail to finish and leave no file,
/// instead of returning the URL of an empty file as a success.
struct EmptyRecordingTests {
    @Test("An audio-only recording whose samples all go to a missing input throws and leaves no file")
    func droppedSamplesThrow() async throws {
        let url = Self.outputURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "dropped", audioSourceIDs: ["microphone"], videoEnabled: false)
        for i in 0..<50 {  // no input for "mixed", as in Creator before #23
            await encoder.encodeAudioSample(Self.sample(i), sourceID: "mixed")
            try await Task.sleep(for: .milliseconds(2))
        }

        await Self.expectNoMediaWritten(encoder, url: url)
    }

    @Test("An audio-only recording that received no samples throws and leaves no file")
    func noSamplesThrow() async throws {
        let url = Self.outputURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "silent", audioSourceIDs: ["microphone"], videoEnabled: false)

        await Self.expectNoMediaWritten(encoder, url: url)
    }

    @Test("A dropped sample does not start the audio-only session")
    func droppedSampleDoesNotSetStartTime() async throws {
        let url = Self.outputURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "stray", audioSourceIDs: ["microphone"], videoEnabled: false)
        // A sample 10 s ahead with no input. If it started the session, every real
        // sample below would fall before the start and be dropped.
        let stray = AudioMixerTests.buffer(frames: 960, value: 1000, pts: CMTime(value: 10, timescale: 1))
        await encoder.encodeAudioSample(stray, sourceID: "unknown")
        for i in 0..<50 {
            await encoder.encodeAudioSample(Self.sample(i), sourceID: "microphone")
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = try await encoder.finishRecording()

        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(duration > 0.5)
    }

    private static func outputURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("empty-recording-\(UUID().uuidString).m4a")
    }

    /// 20 ms of 48 kHz stereo PCM, the `index`th from time zero
    private static func sample(_ index: Int) -> CMSampleBuffer {
        AudioMixerTests.buffer(frames: 960, value: 1000, pts: CMTime(value: CMTimeValue(index * 960), timescale: 48000))
    }

    private static func expectNoMediaWritten(_ encoder: VideoEncoder, url: URL) async {
        do {
            let returned = try await encoder.finishRecording()
            Issue.record("finishRecording returned \(returned.lastPathComponent) for a recording with no media")
        } catch RecorderError.noMediaWritten {
        } catch {
            Issue.record("expected RecorderError.noMediaWritten, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await !encoder.isRecording)
    }
}
