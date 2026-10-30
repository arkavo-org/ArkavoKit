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

    @Test("Stopping while a first-frame wait is still starting ends the wait before the start finishes")
    func stopDuringStartEndsFirstFrameWait() async throws {
        let captureSession = LifecycleRecordingCaptureSession()
        captureSession.holdStart()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let wait = startFirstFrameWait(manager)

        // Its start is blocked in startRunning on the session queue.
        try await waitUntil { captureSession.startsEntered == 1 }
        manager.stopCapture()
        try await waitUntil { wait.outcome != nil }
        #expect(wait.outcome == .cancelled)

        // The start then finishes on its own and doesn't resume the ended wait again.
        captureSession.releaseStart()
        await manager.waitForSessionQueue()
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test("A newer start ends a first-frame wait whose start is still blocked")
    func replacementDuringStartEndsFirstFrameWait() async throws {
        let captureSession = LifecycleRecordingCaptureSession()
        captureSession.holdStart()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let wait = startFirstFrameWait(manager)
        try await waitUntil { captureSession.startsEntered == 1 }

        try manager.startCapture(displayID: CGMainDisplayID())
        try await waitUntil { wait.outcome != nil }
        #expect(wait.outcome == .cancelled)

        captureSession.releaseStart()
        await manager.waitForSessionQueue()
        try await Task.sleep(for: .milliseconds(50))
        manager.stopCapture()
    }

    @Test("Stopping while waiting for the first frame ends the wait")
    func stopDuringFirstFrameWaitEndsIt() async throws {
        let captureSession = LifecycleRecordingCaptureSession()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let wait = startFirstFrameWait(manager)
        try await waitUntil { captureSession.calls.count == 1 }
        try await Task.sleep(for: .milliseconds(50))   // its start has run; no frame will come
        #expect(wait.outcome == nil)

        manager.stopCapture()
        try await waitUntil { wait.outcome != nil }
        #expect(wait.outcome == .cancelled)
    }

    @Test("A first-frame wait returns on its own capture's first frame and ends when a newer start replaces it")
    func firstFrameWaitFollowsItsOwnCapture() async throws {
        let captureSession = LifecycleRecordingCaptureSession()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let pixel = try #require(createTestPixelBuffer(width: 16, height: 16, red: 255, green: 0, blue: 0))
        let sample = try #require(createTestSampleBuffer(from: pixel))

        let first = startFirstFrameWait(manager)
        try await waitUntil { captureSession.calls.count == 1 }
        let output = try #require(captureSession.outputs.first)
        let connection = try #require(output.connection(with: .video))
        manager.captureOutput(output, didOutput: sample, from: connection)
        try await waitUntil { first.outcome != nil }
        #expect(first.outcome == .returned)

        let second = startFirstFrameWait(manager)
        try await waitUntil { captureSession.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        try manager.startCapture(displayID: CGMainDisplayID())
        try await waitUntil { second.outcome != nil }
        #expect(second.outcome == .cancelled)
        manager.stopCapture()
    }

    @Test("Cancelling the task waiting for the first frame ends the wait")
    func cancellingTheWaitingTaskEndsTheWait() async throws {
        let captureSession = LifecycleRecordingCaptureSession()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let wait = startFirstFrameWait(manager)
        try await waitUntil { captureSession.calls.count == 1 }
        try await Task.sleep(for: .milliseconds(50))   // its start has run; no frame will come
        #expect(wait.outcome == nil)

        // CaptureSourceRegistry cancels a start that outlives its timeout.
        wait.task.cancel()
        try await waitUntil { wait.outcome != nil }
        #expect(wait.outcome == .cancelled)
        manager.stopCapture()
    }

    @Test("Cancelling a task whose start is still blocked ends its wait before the start finishes")
    func taskCancelledDuringStartDoesNotWait() async throws {
        let captureSession = LifecycleRecordingCaptureSession()
        captureSession.holdStart()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let wait = startFirstFrameWait(manager)
        try await waitUntil { captureSession.startsEntered == 1 }

        wait.task.cancel()
        try await waitUntil { wait.outcome != nil }
        #expect(wait.outcome == .cancelled)

        // The start then succeeds on its own and doesn't resume the ended wait again.
        captureSession.releaseStart()
        await manager.waitForSessionQueue()
        try await Task.sleep(for: .milliseconds(50))
        manager.stopCapture()
    }

    @Test("A start that fails after its wait was cancelled doesn't resume the wait again")
    func startFailingAfterCancelDoesNotResumeAgain() async throws {
        let captureSession = LifecycleRecordingCaptureSession()
        captureSession.holdStart()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        // A first start holds the session queue in startRunning; the waited start queues behind it.
        try manager.startCapture(displayID: CGMainDisplayID())
        try await waitUntil { captureSession.startsEntered == 1 }
        captureSession.rejectsInputs = true
        let wait = startFirstFrameWait(manager)
        try await Task.sleep(for: .milliseconds(20))

        wait.task.cancel()
        try await waitUntil { wait.outcome != nil }
        #expect(wait.outcome == .cancelled)

        captureSession.releaseStart()
        await manager.waitForSessionQueue()   // the waited start now fails: cannotAddInput
        try await Task.sleep(for: .milliseconds(50))
        manager.stopCapture()
    }

    @Test("A replacement the session can't take leaves the working display capturing and reports it")
    func rejectedReplacementKeepsTheWorkingCapture() async throws {
        let captureSession = SelectiveCaptureSession()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let frames = OSAllocatedUnfairLock(initialState: 0)
        manager.onFrame = { _ in frames.withLock { $0 += 1 } }
        let errors = OSAllocatedUnfairLock(initialState: [RecorderError?]())
        manager.onCaptureError = { error in errors.withLock { $0.append(error as? RecorderError) } }
        let sample = try Self.testSample()
        try manager.startCapture(displayID: CGMainDisplayID())
        await manager.waitForSessionQueue()
        let original = try #require(captureSession.inputs.first)
        let output = try #require(captureSession.outputs.first)

        captureSession.rejectsNewInputs = true
        try manager.startCapture(displayID: CGMainDisplayID())
        await manager.waitForSessionQueue()
        try await waitUntil { !errors.withLock { $0 }.isEmpty }

        #expect(errors.withLock { $0 } == [.cannotAddInput])
        #expect(captureSession.inputs.count == 1)
        #expect(captureSession.inputs.first === original)
        // The original display's frames still route. Its connection may be new after the rollback.
        let connection = try #require(output.connection(with: .video))
        manager.captureOutput(output, didOutput: sample, from: connection)
        #expect(frames.withLock { $0 } == 1)
        manager.stopCapture()
    }

    @Test("A first-frame wait for a display the session can't take throws; the working display keeps capturing")
    func rejectedReplacementWaitThrows() async throws {
        let captureSession = SelectiveCaptureSession()
        let manager = ScreenCaptureManager(captureSession: captureSession)
        let frames = OSAllocatedUnfairLock(initialState: 0)
        manager.onFrame = { _ in frames.withLock { $0 += 1 } }
        let errors = OSAllocatedUnfairLock(initialState: 0)
        manager.onCaptureError = { _ in errors.withLock { $0 += 1 } }
        let sample = try Self.testSample()
        try manager.startCapture(displayID: CGMainDisplayID())
        await manager.waitForSessionQueue()
        let output = try #require(captureSession.outputs.first)

        captureSession.rejectsNewInputs = true
        var thrown: (any Error)?
        do {
            try await manager.startCaptureAndWaitForFirstFrame(displayID: CGMainDisplayID())
        } catch {
            thrown = error
        }
        #expect(thrown as? RecorderError == .cannotAddInput)
        try await Task.sleep(for: .milliseconds(50))
        #expect(errors.withLock { $0 } == 0)   // the waiter's caller gets the error, not the callback

        let connection = try #require(output.connection(with: .video))
        manager.captureOutput(output, didOutput: sample, from: connection)
        #expect(frames.withLock { $0 } == 1)
        manager.stopCapture()
    }

    @Test("RecordingSession reports a screen preview switch the session can't take")
    func recordingSessionReportsRejectedPreviewSwitch() async throws {
        let captureSession = SelectiveCaptureSession()
        let capture = ScreenCaptureManager(captureSession: captureSession)
        let session = try RecordingSession(screenCapture: capture)
        let errors = OSAllocatedUnfairLock(initialState: [RecorderError?]())
        session.screenCaptureFailureHandler = { error in errors.withLock { $0.append(error as? RecorderError) } }
        try session.startScreenPreview()
        await capture.waitForSessionQueue()

        captureSession.rejectsNewInputs = true
        try session.startScreenPreview()
        await capture.waitForSessionQueue()
        try await waitUntil { !errors.withLock { $0 }.isEmpty }
        #expect(errors.withLock { $0 } == [.cannotAddInput])
        session.stopScreenPreview()
    }

    private static func testSample() throws -> CMSampleBuffer {
        let pixel = try #require(createTestPixelBuffer(width: 16, height: 16, red: 255, green: 0, blue: 0))
        return try #require(createTestSampleBuffer(from: pixel))
    }
}

private enum FirstFrameWaitOutcome: Equatable { case returned, cancelled, failed }

/// A `startCaptureAndWaitForFirstFrame` call running in `task`.
private struct FirstFrameWait {
    let task: Task<Void, Never>
    private let ending: OSAllocatedUnfairLock<FirstFrameWaitOutcome?>

    init(task: Task<Void, Never>, ending: OSAllocatedUnfairLock<FirstFrameWaitOutcome?>) {
        self.task = task
        self.ending = ending
    }

    /// How the call ended, once it has.
    var outcome: FirstFrameWaitOutcome? { ending.withLock { $0 } }
}

/// Starts `startCaptureAndWaitForFirstFrame` in a task.
@MainActor
private func startFirstFrameWait(_ manager: ScreenCaptureManager) -> FirstFrameWait {
    let ending = OSAllocatedUnfairLock<FirstFrameWaitOutcome?>(initialState: nil)
    let task = Task { @MainActor in
        do {
            try await manager.startCaptureAndWaitForFirstFrame(displayID: CGMainDisplayID())
            ending.withLock { $0 = .returned }
        } catch is CancellationError {
            ending.withLock { $0 = .cancelled }
        } catch {
            ending.withLock { $0 = .failed }
        }
    }
    return FirstFrameWait(task: task, ending: ending)
}

/// Polls `condition` for up to two seconds, so a wait that never ends fails instead of hanging.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() && .now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Exercise AVFoundation's real input configuration without capturing the user's screen.
private final class ConfigurationOnlyCaptureSession: AVCaptureSession, @unchecked Sendable {
    override func startRunning() {}
    override func stopRunning() {}
}

/// Takes inputs until `rejectsNewInputs` is set, then refuses any input it hasn't held before,
/// as a session does when it can't take a display's input, while still taking back one it held.
/// Captures nothing.
private final class SelectiveCaptureSession: AVCaptureSession, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (rejecting: false, held: Set<ObjectIdentifier>()))

    var rejectsNewInputs: Bool {
        get { state.withLock { $0.rejecting } }
        set { state.withLock { $0.rejecting = newValue } }
    }

    override func canAddInput(_ input: AVCaptureInput) -> Bool {
        let id = ObjectIdentifier(input)
        let refused = state.withLock { $0.rejecting && !$0.held.contains(id) }
        return !refused && super.canAddInput(input)
    }

    override func addInput(_ input: AVCaptureInput) {
        let id = ObjectIdentifier(input)
        state.withLock { _ = $0.held.insert(id) }
        super.addInput(input)
    }

    override func startRunning() {}
    override func stopRunning() {}
}

/// Records each `startRunning` / `stopRunning` with the thread it ran on, in completion order,
/// without capturing the user's screen. Each call takes `latency` seconds; `holdStart()` makes
/// `startRunning` block, as a real session does while it starts, until `releaseStart()` (or a
/// five-second safety timeout, longer than any test's deadline). `rejectsInputs` refuses inputs.
private final class LifecycleRecordingCaptureSession: AVCaptureSession, @unchecked Sendable {
    enum Kind: Equatable { case start, stop }
    struct Call { let kind: Kind; let onMainThread: Bool }

    private let latency: TimeInterval
    private let state = OSAllocatedUnfairLock(
        initialState: (calls: [Call](), running: false, holdsStart: false, startsEntered: 0, rejectsInputs: false)
    )
    private let startGate = DispatchSemaphore(value: 0)

    init(latency: TimeInterval = 0) {
        self.latency = latency
        super.init()
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var isRunningStub: Bool { state.withLock { $0.running } }
    /// `startRunning` calls that have begun, including one still blocked.
    var startsEntered: Int { state.withLock { $0.startsEntered } }

    var rejectsInputs: Bool {
        get { state.withLock { $0.rejectsInputs } }
        set { state.withLock { $0.rejectsInputs = newValue } }
    }

    func holdStart() { state.withLock { $0.holdsStart = true } }

    func releaseStart() {
        state.withLock { $0.holdsStart = false }
        startGate.signal()
    }

    override func startRunning() {
        state.withLock { $0.startsEntered += 1 }
        if state.withLock({ $0.holdsStart }) {
            _ = startGate.wait(timeout: .now() + 5)
        }
        record(.start, running: true)
    }

    override func stopRunning() {
        record(.stop, running: false)
    }

    override func canAddInput(_ input: AVCaptureInput) -> Bool {
        !rejectsInputs && super.canAddInput(input)
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
