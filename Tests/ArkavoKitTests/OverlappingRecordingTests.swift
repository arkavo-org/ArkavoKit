import Testing
import AVFoundation
import CoreMedia
@testable import ArkavoRecorder

/// `finishRecording()` suspends while the file is finished. A recording started in that
/// window must not be accepted and then torn down by the first recording's cleanup.
struct OverlappingRecordingTests {
    @Test("A start while the previous recording is finishing doesn't lose either recording")
    func startDuringFinishKeepsBothRecordings() async throws {
        let first = Self.outputURL()
        let second = Self.outputURL()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let encoder = VideoEncoder()
        try await encoder.startRecording(to: first, title: "first", audioSourceIDs: ["microphone"], videoEnabled: false)
        try await Self.feedAudio(encoder)

        let finishFirst = Task { try await encoder.finishRecording() }
        // isRecording turns false just before finishRecording() suspends to finish the file
        while await encoder.isRecording { await Task.yield() }
        var secondStarted = true
        do {
            try await encoder.startRecording(to: second, title: "second", audioSourceIDs: ["microphone"], videoEnabled: false)
        } catch RecorderError.recordingFailed {
            secondStarted = false
        }

        let firstURL = try await finishFirst.value
        #expect(firstURL == first)
        #expect(try await AVURLAsset(url: first).load(.duration).seconds > 0.4)

        if !secondStarted {
            try await encoder.startRecording(to: second, title: "second", audioSourceIDs: ["microphone"], videoEnabled: false)
        }
        try await Self.feedAudio(encoder)
        let secondURL = try await encoder.finishRecording()
        #expect(secondURL == second)
        #expect(try await AVURLAsset(url: second).load(.duration).seconds > 0.4)
    }

    private static func outputURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("overlap-\(UUID().uuidString).m4a")
    }

    /// 0.5 s of 20 ms buffers from time zero, one every 20 ms as capture delivers them (the
    /// writer's inputs are real-time; a faster feed outruns a slow machine)
    private static func feedAudio(_ encoder: VideoEncoder) async throws {
        for i in 0..<25 {
            let pts = CMTime(value: CMTimeValue(i * 960), timescale: 48000)
            await encoder.encodeAudioSample(AudioMixerTests.buffer(frames: 960, value: 1000, pts: pts), sourceID: "microphone")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
