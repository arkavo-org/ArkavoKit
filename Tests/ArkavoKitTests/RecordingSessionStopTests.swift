import Testing
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
}
