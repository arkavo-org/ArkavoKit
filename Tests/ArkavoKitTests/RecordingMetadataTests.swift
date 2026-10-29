import AVFoundation
import Foundation
import Testing
@testable import ArkavoRecorder

struct RecordingMetadataTests {
    @Test("Saved recording software identifies the hosting application and its version")
    func exportedSoftwareUsesHostIdentity() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("software-metadata-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "host metadata", audioSourceIDs: ["microphone"], videoEnabled: false)
        for index in 0..<10 {
            let pts = CMTime(value: CMTimeValue(index * 960), timescale: 48000)
            await encoder.encodeAudioSample(AudioMixerTests.buffer(frames: 960, value: 1000, pts: pts), sourceID: "microphone")
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await encoder.finishRecording()

        let metadata = try await AVURLAsset(url: url).load(.commonMetadata)
        let item = try #require(metadata.first { $0.commonKey == .commonKeySoftware })
        let software = try #require(try await item.load(.stringValue))
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? ProcessInfo.processInfo.processName
        #expect(software.hasPrefix(name))
        if let version = info["CFBundleShortVersionString"] as? String {
            #expect(software.contains(version))
        }
        if let build = info["CFBundleVersion"] as? String {
            #expect(software.contains(build))
        }
        #expect(software != "Arkavo Creator v1.0")
    }
}
