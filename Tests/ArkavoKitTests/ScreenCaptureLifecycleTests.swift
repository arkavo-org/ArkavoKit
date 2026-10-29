import AVFoundation
import CoreGraphics
import Testing
@testable import ArkavoRecorder

@MainActor
struct ScreenCaptureLifecycleTests {
    @Test("Stopping then restarting capture keeps the newly selected screen input")
    func stopThenRestartKeepsReplacementInput() async throws {
        let captureSession = ConfigurationOnlyCaptureSession()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        try manager.startCapture(displayID: CGMainDisplayID())
        let original = try #require(captureSession.inputs.first)

        manager.stopCapture()
        try manager.startCapture(displayID: CGMainDisplayID())
        let replacement = try #require(captureSession.inputs.first)
        #expect(replacement !== original)

        // Flush work enqueued by start/stop. A stale stop must not remove this input.
        try await Task.sleep(for: .milliseconds(50))
        #expect(captureSession.inputs.count == 1)
        #expect(captureSession.inputs.first === replacement)
        manager.stopCapture()
    }

    @Test("Stopping screen capture removes the input before returning")
    func stopCompletesConfigurationBeforeReturning() throws {
        let captureSession = ConfigurationOnlyCaptureSession()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        try manager.startCapture(displayID: CGMainDisplayID())
        #expect(captureSession.inputs.count == 1)
        manager.stopCapture()
        #expect(captureSession.inputs.isEmpty)
    }
}

/// Exercise AVFoundation's real input configuration without capturing the user's screen.
private final class ConfigurationOnlyCaptureSession: AVCaptureSession, @unchecked Sendable {
    override func startRunning() {}
    override func stopRunning() {}
}
