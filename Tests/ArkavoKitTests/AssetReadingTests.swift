import Testing
import AVFoundation
import CoreMedia
import os
@testable import ArkavoRecorder

struct AssetReadingTests {
    @Test("As many reads at once as the pool has threads all finish")
    func asManyReadsAsPoolThreadsFinish() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reading-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "reading", audioSourceIDs: ["microphone"], videoEnabled: false)
        for i in 0..<10 {
            let pts = CMTime(value: CMTimeValue(i * 960), timescale: 48000)
            await encoder.encodeAudioSample(AudioMixerTests.buffer(frames: 960, value: 1000, pts: pts), sourceID: "microphone")
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try await encoder.finishRecording()
        let once = try await DroppedMediaTests.decodedFrames(url)

        // Each read waits until all have started, so every one is inside the reader at once.
        let readers = ProcessInfo.processInfo.activeProcessorCount
        let started = OSAllocatedUnfairLock(initialState: 0)
        // Nothing ends the deadlock, not even cancelling the readers, and while it lasts no work
        // on the cooperative pool or GCD's global queues runs: from a thread of its own, stop the
        // run rather than let it hang.
        let finished = OSAllocatedUnfairLock(initialState: false)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 60)
            if !finished.withLock({ $0 }) {
                fatalError("\(readers) reads at once never finished: a read on the cooperative pool blocks its thread (readingOffThePool)")
            }
        }
        let frames = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<readers {
                group.addTask {
                    try await readingOffThePool {
                        try await Self.decodedFrames(url, afterStarting: started, of: readers)
                    }
                }
            }
            return try await group.reduce(0, +)
        }
        finished.withLock { $0 = true }

        #expect(frames == readers * once)
    }

    /// Decoded frames in the file, read once `count` reads have started
    private static func decodedFrames(_ url: URL, afterStarting started: OSAllocatedUnfairLock<Int>, of count: Int) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        let buffers = reader.outputProvider(for: output)
        try reader.start()
        started.withLock { $0 += 1 }
        while started.withLock({ $0 }) < count { usleep(1_000) }
        var frames = 0
        while let buffer = try await buffers.next() {
            frames += buffer.sampleCount
        }
        return frames
    }
}
