import Foundation
import Testing
@testable import ArkavoRecorder

@MainActor
struct RecordingSessionDurationTests {
    @Test("Elapsed recording time freezes during every pause and resumes from that time")
    func elapsedTimeExcludesMultiplePauses() async throws {
        let session = try Self.sessionWithoutDevices()
        let url = Self.outputURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await session.startRecording(outputURL: url, title: "elapsed time")

        for _ in 0..<2 {
            let before = session.duration
            try await Task.sleep(for: .milliseconds(40))
            session.pauseRecording()
            let paused = session.duration
            #expect(paused > before)
            try await Task.sleep(for: .milliseconds(80))
            session.pauseRecording() // Repeating pause must preserve the original boundary.
            #expect(session.duration == paused)
            session.resumeRecording()
            session.resumeRecording()
            #expect(abs(session.duration - paused) < 0.04)
        }

        await Self.stopEmptyRecording(session)
    }

    @Test("Stopping while paused resets elapsed time for a new recording")
    func restartResetsPausedElapsedTime() async throws {
        let session = try Self.sessionWithoutDevices()
        let url = Self.outputURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await session.startRecording(outputURL: url, title: "first")
        try await Task.sleep(for: .milliseconds(100))
        session.pauseRecording()
        let firstDuration = session.duration
        await Self.stopEmptyRecording(session)
        #expect(session.duration == 0)

        try await session.startRecording(outputURL: url, title: "second")
        #expect(session.duration < firstDuration)
        let restarted = session.duration
        try await Task.sleep(for: .milliseconds(40))
        #expect(session.duration > restarted)
        await Self.stopEmptyRecording(session)
        #expect(session.duration == 0)
    }

    @Test("Pause and resume outside a recording do not start its clock")
    func idlePauseAndResumeAreNoOps() async throws {
        let session = try Self.sessionWithoutDevices()
        session.pauseRecording()
        session.resumeRecording()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!session.isRecording)
        #expect(session.duration == 0)
    }

    private static func sessionWithoutDevices() throws -> RecordingSession {
        let session = try RecordingSession()
        session.enableDesktop = false
        session.enableCamera = false
        session.enableMicrophone = false
        session.enableAvatar = true
        return session
    }

    private static func outputURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("elapsed-\(UUID().uuidString).mov")
    }

    private static func stopEmptyRecording(_ session: RecordingSession) async {
        do {
            _ = try await session.stopRecording()
            Issue.record("A recording without media unexpectedly produced a file")
        } catch RecorderError.noMediaWritten {
        } catch {
            Issue.record("Unexpected stop error: \(error)")
        }
    }
}
