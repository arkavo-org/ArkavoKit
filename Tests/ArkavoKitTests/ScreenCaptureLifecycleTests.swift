import AVFoundation
import CoreGraphics
import os
import Testing
@testable import ArkavoRecorder

@MainActor
struct ScreenCaptureLifecycleTests {
    @Test("Callbacks from a replaced display are discarded while the current display still delivers")
    func replacedDisplayCannotDeliverFrames() async throws {
        let captureSession = ConfigurationOnlyCaptureSession()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let frames = OSAllocatedUnfairLock(initialState: 0)
        manager.onFrame = { _ in frames.withLock { $0 += 1 } }
        let pixel = try #require(createTestPixelBuffer(width: 16, height: 16, red: 255, green: 0, blue: 0))
        let sample = try #require(createTestSampleBuffer(from: pixel))
        try manager.startCapture()
        await manager.waitForSessionQueue()
        let output = try #require(captureSession.outputs.first)
        let oldConnection = try #require(output.connection(with: .video))

        try manager.startCapture()
        // The replaced display is cut off once the replacement is requested, before it's attached.
        manager.captureOutput(output, didOutput: sample, from: oldConnection)
        #expect(frames.withLock { $0 } == 0)
        await manager.waitForSessionQueue()
        let newConnection = try #require(output.connection(with: .video))
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
        await manager.waitForSessionQueue()
        let original = try #require(captureSession.inputs.first)

        manager.stopCapture()
        try manager.startCapture(displayID: CGMainDisplayID())

        // Once both have run, the stop must not have removed the replacement input.
        await manager.waitForSessionQueue()
        #expect(captureSession.inputs.count == 1)
        let replacement = try #require(captureSession.inputs.first)
        #expect(replacement !== original)
        manager.stopCapture()
    }

    @Test("Stopping screen capture drops frames before returning, then removes the input")
    func stopDropsFramesThenRemovesInput() async throws {
        let captureSession = ConfigurationOnlyCaptureSession()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let frames = OSAllocatedUnfairLock(initialState: 0)
        manager.onFrame = { _ in frames.withLock { $0 += 1 } }
        let pixel = try #require(createTestPixelBuffer(width: 16, height: 16, red: 255, green: 0, blue: 0))
        let sample = try #require(createTestSampleBuffer(from: pixel))
        try manager.startCapture(displayID: CGMainDisplayID())
        await manager.waitForSessionQueue()
        #expect(captureSession.inputs.count == 1)
        let output = try #require(captureSession.outputs.first)
        let connection = try #require(output.connection(with: .video))

        manager.stopCapture()
        manager.captureOutput(output, didOutput: sample, from: connection)
        #expect(frames.withLock { $0 } == 0)
        await manager.waitForSessionQueue()
        #expect(captureSession.inputs.isEmpty)
    }

    @Test("Starting and stopping from the main actor return without waiting for the session")
    func blockingSessionCallsRunOffTheMainThread() async throws {
        let captureSession = LifecycleRecordingCaptureSession()
        captureSession.holdStart()
        let manager = ScreenCaptureManager(captureSession: captureSession)

        try manager.startCapture(displayID: CGMainDisplayID())
        // startRunning blocks until released, so it cannot have finished on this thread.
        #expect(captureSession.calls.isEmpty)
        captureSession.releaseStart()
        manager.stopCapture()

        await manager.waitForSessionQueue()
        #expect(captureSession.calls.map(\.kind) == [.start, .stop])
        #expect(captureSession.calls.allSatisfy { !$0.onMainThread })
    }

    @Test("Rapid display switches run in caller order and settle on the last request")
    func rapidStartStopSettlesOnTheLastRequest() async throws {
        // Each call takes longer than the caller takes to make the next, so requests queue up.
        let captureSession = LifecycleRecordingCaptureSession(latency: 0.005)
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let frames = OSAllocatedUnfairLock(initialState: 0)
        manager.onFrame = { _ in frames.withLock { $0 += 1 } }
        let pixel = try #require(createTestPixelBuffer(width: 16, height: 16, red: 255, green: 0, blue: 0))
        let sample = try #require(createTestSampleBuffer(from: pixel))

        // Main, then display 2 in place, then a stop and display 3 twice.
        try manager.startCapture(displayID: CGMainDisplayID())
        try manager.startCapture(displayID: CGMainDisplayID())
        manager.stopCapture()
        try manager.startCapture(displayID: CGMainDisplayID())
        try manager.startCapture(displayID: CGMainDisplayID())
        await manager.waitForSessionQueue()

        #expect(captureSession.calls.map(\.kind) == [.start, .start, .stop, .start, .start])
        #expect(captureSession.isRunningStub)
        #expect(captureSession.inputs.count == 1)
        let output = try #require(captureSession.outputs.first)
        let connection = try #require(output.connection(with: .video))
        manager.captureOutput(output, didOutput: sample, from: connection)
        #expect(frames.withLock { $0 } == 1)

        try manager.startCapture(displayID: CGMainDisplayID())
        manager.stopCapture()
        await manager.waitForSessionQueue()

        #expect(captureSession.calls.map(\.kind).suffix(2) == [.start, .stop])
        #expect(!captureSession.isRunningStub)
        #expect(captureSession.inputs.isEmpty)
        #expect(captureSession.calls.allSatisfy { !$0.onMainThread })
    }
}

/// Exercise AVFoundation's real input configuration without capturing the user's screen.
private final class ConfigurationOnlyCaptureSession: AVCaptureSession, @unchecked Sendable {
    override func startRunning() {}
    override func stopRunning() {}
}

/// Records each `startRunning` / `stopRunning` with the thread it ran on, in completion order,
/// without capturing the user's screen. Each call takes `latency` seconds; `holdStart()` makes
/// `startRunning` block, as a real session does while it starts, until `releaseStart()` (or a
/// one-second timeout).
private final class LifecycleRecordingCaptureSession: AVCaptureSession, @unchecked Sendable {
    enum Kind: Equatable { case start, stop }
    struct Call { let kind: Kind; let onMainThread: Bool }

    private let latency: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: (calls: [Call](), running: false, holdsStart: false))
    private let startGate = DispatchSemaphore(value: 0)

    init(latency: TimeInterval = 0) {
        self.latency = latency
        super.init()
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var isRunningStub: Bool { state.withLock { $0.running } }

    func holdStart() { state.withLock { $0.holdsStart = true } }

    func releaseStart() {
        state.withLock { $0.holdsStart = false }
        startGate.signal()
    }

    override func startRunning() {
        if state.withLock({ $0.holdsStart }) {
            _ = startGate.wait(timeout: .now() + 1)
        }
        record(.start, running: true)
    }

    override func stopRunning() {
        record(.stop, running: false)
    }

    private func record(_ kind: Kind, running: Bool) {
        Thread.sleep(forTimeInterval: latency)
        let onMain = Thread.isMainThread
        state.withLock {
            $0.calls.append(Call(kind: kind, onMainThread: onMain))
            $0.running = running
        }
    }
}
