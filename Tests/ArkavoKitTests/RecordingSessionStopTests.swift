import Testing
import AVFoundation
import Foundation
@testable import ArkavoRecorder

/// A stop that fails still ends the recording: the session must not keep reporting
/// that it is recording and routing frames to a finished encoder.
@MainActor
struct RecordingSessionStopTests {
    @Test("A failed stop leaves the session not recording")
    func failedStopEndsRecording() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-stop-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        // Avatar mode with no avatar frames: needs no permissions and writes no media,
        // so finishing the file fails with noMediaWritten
        let session = try RecordingSession()
        session.enableDesktop = false
        session.enableCamera = false
        session.enableMicrophone = false
        session.enableAvatar = true
        try await session.startRecording(outputURL: url, title: "failed stop")
        #expect(session.isRecording)

        do {
            _ = try await session.stopRecording()
            Issue.record("stopRecording returned a URL for a recording with no media")
        } catch RecorderError.noMediaWritten {
        }

        #expect(!session.isRecording)
        #expect(session.duration == 0)
    }

    @Test("Stopping a recording keeps a sound the mixer was still buffering")
    func stopKeepsBufferedSound() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("buffered-sound-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        // Avatar mode needs no permissions; a stand-in clock source and the Muse voice feed the mixer
        let session = try RecordingSession()
        session.enableDesktop = false
        session.enableCamera = false
        session.enableMicrophone = false
        session.enableScreenAudio = false
        session.enableAvatar = true
        session.watermarkEnabled = false
        session.avatarTextureProvider = { createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 255, blue: 0) }
        let clock = FakeAudioSource(sourceID: "test-clock")
        let voice = FakeAudioSource(sourceID: "muse-voice")
        session.addMuseAudioSource(clock)
        session.addMuseAudioSource(voice)
        try await session.startRecording(outputURL: url, title: "buffered sound")

        // Half a second of a silent clock in real time, then a 20 ms tone and one more clock
        // buffer: when the recording stops, the tone is still short of the mixer's prefill.
        for _ in 0..<24 {
            clock.onSample?(Self.tone(frames: 1024, amplitude: 0))
            try await Task.sleep(for: .milliseconds(21))
        }
        voice.onSample?(Self.tone(frames: 960, amplitude: 8000))
        clock.onSample?(Self.tone(frames: 1024, amplitude: 0))
        _ = try await session.stopRecording()

        #expect(try await Self.peakAudioSample(in: url) > 2000)
    }

    /// A 1 kHz tone (silence at amplitude 0) stamped with the host clock, as capture sources are.
    private static func tone(frames: Int, amplitude: Double) -> CMSampleBuffer {
        AudioMixerTests.buffer(frames: frames, pts: CMClockGetTime(CMClockGetHostTimeClock())) { frame in
            Int16(amplitude * sin(2 * .pi * 1000 * Double(frame) / 48000))
        }
    }

    /// The largest absolute sample value in the file's decoded audio.
    private static func peakAudioSample(in url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var peak = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var samples = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            _ = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            peak = max(peak, samples.map { abs(Int($0)) }.max() ?? 0)
        }
        return peak
    }
}
