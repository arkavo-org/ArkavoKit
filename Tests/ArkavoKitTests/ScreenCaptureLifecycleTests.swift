import AVFoundation
import CoreGraphics
import os
import Testing
@testable import ArkavoRecorder

@MainActor
struct ScreenCaptureLifecycleTests {
    @Test("Callbacks from a replaced display are discarded while the current display still delivers")
    func replacedDisplayCannotDeliverFrames() throws {
        let captureSession = ConfigurationOnlyCaptureSession()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let frames = OSAllocatedUnfairLock(initialState: 0)
        manager.onFrame = { _ in frames.withLock { $0 += 1 } }
        try manager.startCapture()
        let output = try #require(captureSession.outputs.first)
        let oldConnection = try #require(output.connection(with: .video))
        try manager.startCapture()
        let newConnection = try #require(output.connection(with: .video))
        let pixel = try #require(createTestPixelBuffer(width: 16, height: 16, red: 255, green: 0, blue: 0))
        let sample = try #require(createTestSampleBuffer(from: pixel))
        manager.captureOutput(output, didOutput: sample, from: oldConnection)
        #expect(frames.withLock { $0 } == 0)
        manager.captureOutput(output, didOutput: sample, from: newConnection)
        #expect(frames.withLock { $0 } == 1)
        manager.stopCapture()
        manager.captureOutput(output, didOutput: sample, from: newConnection)
        #expect(frames.withLock { $0 } == 1)
    }

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
