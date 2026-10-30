#if os(macOS)
@preconcurrency import AVFoundation
import CoreGraphics
import os
#if canImport(AppKit)
import AppKit
#endif

/// Manages screen capture using AVFoundation.
///
/// `AVCaptureSession.startRunning()` and `stopRunning()` block until the session has started
/// or stopped, and must not run on the main thread. Every change to the session (its outputs
/// and inputs, `startRunning` and `stopRunning`) therefore runs on `CaptureGraph.queue`, a
/// private serial queue, in the order the calls were made; `startCapture` and `stopCapture`
/// return without waiting for it. Frame routing doesn't wait for the queue either: the
/// capture a frame must belong to changes before each call returns, so frames from a replaced
/// or stopped display are dropped at once.
@MainActor
public final class ScreenCaptureManager: NSObject, Sendable {
    // MARK: - Properties

    private let graph: CaptureGraph

    private let outputQueue = DispatchQueue(label: "com.arkavo.screencapture")

    nonisolated(unsafe) public var onFrame: (@Sendable (CMSampleBuffer) -> Void)?
    /// Called on the main actor when `startCapture` can't attach its display because the session
    /// can't take its input (`RecorderError.cannotAddInput`). The display captured before keeps
    /// capturing. `startCaptureAndWaitForFirstFrame` throws instead.
    public var onCaptureError: (@MainActor (any Error) -> Void)?
    nonisolated(unsafe) var onFrameForCapture: (@Sendable (CMSampleBuffer, UUID) -> Void)?
    private let activeCapture = OSAllocatedUnfairLock<ActiveCapture?>(initialState: nil)

    nonisolated func isCurrentCapture(_ id: UUID) -> Bool {
        activeCapture.withLock { $0?.id == id }
    }

    /// The `startCaptureAndWaitForFirstFrame` call waiting for its capture to start and deliver a
    /// first frame. Registered before the start is queued, and resumed exactly once, on the main
    /// actor, by whichever comes first: that capture's first frame, its failed start, a stop, a
    /// newer start, or cancellation of the calling task.
    private var firstFrameWaiter: (captureID: UUID, continuation: CheckedContinuation<Void, any Error>)?
    private var hasDeliveredFirstFrame: Bool = false

    // MARK: - Initialization

    public override convenience init() {
        self.init(captureSession: AVCaptureSession())
    }

    init(captureSession: AVCaptureSession) {
        self.graph = CaptureGraph(session: captureSession)

        super.init()

        let graph = graph, outputQueue = outputQueue
        graph.queue.async { [self] in
            graph.configure(delegate: self, callbackQueue: outputQueue)
        }
    }

    // MARK: - Public Methods

    /// Starts screen capture for the specified display (or main display if nil), replacing
    /// any display already being captured.
    ///
    /// Returns once the request is queued; the session is reconfigured and started on the
    /// session queue, after any earlier start or stop. Throws
    /// `RecorderError.screenCaptureUnavailable` when the display can't be captured. If the
    /// session then can't take the display's input, the display captured before keeps
    /// capturing and `onCaptureError` receives `RecorderError.cannotAddInput`.
    public func startCapture(displayID: CGDirectDisplayID? = nil) throws {
        #if os(macOS)
        let request = try beginCapture(displayID: displayID)
        enqueueStart(request, reportsFailure: true)
        #else
        throw RecorderError.screenCaptureUnavailable
        #endif
    }

    /// Starts screen capture and waits for the first frame to be delivered
    /// This ensures the screen capture is actually producing frames before returning
    ///
    /// Throws `RecorderError.cannotAddInput` if the session can't take the display's input; the
    /// display captured before keeps capturing. Throws `CancellationError` as soon as
    /// `stopCapture`, another start or cancelling the calling task ends the wait, even while the
    /// session is still starting. Ending the wait doesn't undo the start: the session work runs
    /// to completion, and a cancelled call's capture keeps running.
    public func startCaptureAndWaitForFirstFrame(displayID: CGDirectDisplayID? = nil) async throws {
        #if os(macOS)
        let request = try beginCapture(displayID: displayID)
        let captureID = request.captureID

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Register the wait while this capture is current, before its start is queued,
                // so a stop, a newer start or cancellation can end it while startRunning blocks.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    firstFrameWaiter = (captureID, continuation)
                }
                // Start even when already cancelled: routing points at this capture now.
                enqueueStart(request, reportsFailure: false) { [weak self] result in
                    // A successful start waits for the frame; a failed one ends the wait.
                    guard case .failure(let error) = result else { return }
                    Task { @MainActor [weak self] in self?.endFirstFrameWait(of: captureID, throwing: error) }
                }
            }
        } onCancel: { [weak self] in
            // Runs on the cancelling thread. The hop reaches the main actor after the wait is
            // registered, which happens in the same main-actor job that enters this handler.
            Task { @MainActor [weak self] in self?.endFirstFrameWait(of: captureID) }
        }

        print("🖥️ [ScreenCaptureManager] First frame delivered, capture ready")
        #else
        throw RecorderError.screenCaptureUnavailable
        #endif
    }

    /// Stops screen capture.
    ///
    /// Frames stop being delivered before this returns; the session is stopped and its input
    /// removed on the session queue, after any earlier start.
    public func stopCapture() {
        activeCapture.withLock { $0 = nil }
        let graph = graph
        graph.queue.async { graph.stop() }

        // Reset state
        hasDeliveredFirstFrame = false
        endFirstFrameWait()
    }

    /// Returns once every session change requested before the call has run on the session queue.
    func waitForSessionQueue() async {
        let queue = graph.queue
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    // MARK: - Capture Requests

    private struct StartRequest: @unchecked Sendable {
        /// Created and configured on the caller's thread, then used only on the session queue.
        let input: AVCaptureScreenInput
        let captureID: UUID
    }

    /// Creates the input for `displayID` and routes frames to it from now on. Until the session
    /// queue attaches it, no frame belongs to it, so frames of the input it replaces are dropped.
    private func beginCapture(displayID: CGDirectDisplayID?) throws -> StartRequest {
        guard let input = AVCaptureScreenInput(displayID: displayID ?? CGMainDisplayID()) else {
            throw RecorderError.screenCaptureUnavailable
        }

        input.minFrameDuration = CMTime(value: 1, timescale: 30) // 30 fps
        input.capturesCursor = true
        input.capturesMouseClicks = false

        let capture = ActiveCapture(input: ObjectIdentifier(input), id: UUID())
        activeCapture.withLock { $0 = capture }

        // Reset first frame tracking; a wait for the replaced capture's frame can't succeed now.
        hasDeliveredFirstFrame = false
        endFirstFrameWait()
        return StartRequest(input: input, captureID: capture.id)
    }

    /// Ends a pending first-frame wait with `error`: any wait, or only the one for `captureID`,
    /// so a late cancellation or start failure can't end a newer capture's wait. A wait already
    /// ended isn't resumed again.
    private func endFirstFrameWait(of captureID: UUID? = nil, throwing error: any Error = CancellationError()) {
        guard let waiter = firstFrameWaiter, captureID == nil || waiter.captureID == captureID else { return }
        firstFrameWaiter = nil
        waiter.continuation.resume(throwing: error)
    }

    /// Attaches the request's input and starts the session on the session queue. If the session
    /// can't take the input, the graph keeps the capture it had attached, and frames route back
    /// to it, unless a later start or stop has changed routing since. Only a failure of the
    /// current request is reported to `onCaptureError`, and only when `reportsFailure`.
    private func enqueueStart(
        _ request: StartRequest,
        reportsFailure: Bool,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void = { _ in }
    ) {
        let graph = graph, activeCapture = activeCapture
        graph.queue.async { [weak self] in
            do {
                try graph.start(with: request.input, captureID: request.captureID)
                completion(.success(()))
            } catch {
                let wasCurrent = activeCapture.withLock { state in
                    guard state?.id == request.captureID else { return false }
                    state = graph.attachedCapture
                    return true
                }
                print("🖥️ [ScreenCaptureManager] Screen capture couldn't start: \(error)")
                if wasCurrent && reportsFailure {
                    Task { @MainActor [weak self] in self?.onCaptureError?(error) }
                }
                completion(.failure(error))
            }
        }
    }

    /// Returns available screens with display IDs
    public static func availableScreens() -> [ScreenInfo] {
        #if os(macOS)
        let mainDisplayID = CGMainDisplayID()
        let displays = NSScreen.screens

        return displays.enumerated().compactMap { index, screen in
            // Get the display ID from the screen's deviceDescription
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }

            return ScreenInfo(
                id: index,
                displayID: screenNumber,
                name: screen.localizedName,
                bounds: screen.frame,
                isPrimary: screenNumber == mainDisplayID
            )
        }
        #else
        return []
        #endif
    }

    /// Signal that first frame was received (called from delegate on background queue)
    private func signalFirstFrame(captureID: UUID) {
        guard isCurrentCapture(captureID), !hasDeliveredFirstFrame else { return }
        hasDeliveredFirstFrame = true
        guard let waiter = firstFrameWaiter, waiter.captureID == captureID else { return }
        firstFrameWaiter = nil
        waiter.continuation.resume()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension ScreenCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let input = connection.inputPorts.first?.input,
              let captureID = activeCapture.withLock({ state in
                  state?.input == ObjectIdentifier(input) ? state?.id : nil
              }) else { return }
        // Forward frame to handler - calling directly on callback queue
        // CMSampleBuffer is not Sendable but we handle it synchronously
        onFrame?(sampleBuffer)
        onFrameForCapture?(sampleBuffer, captureID)

        // Signal first frame for async startup
        Task { @MainActor [weak self] in
            self?.signalFirstFrame(captureID: captureID)
        }
    }
}

// MARK: - Capture Graph

/// The capture frames must belong to: the input they come from, and the capture's ID.
private struct ActiveCapture: Sendable {
    let input: ObjectIdentifier
    let id: UUID
}

/// The capture session, its video output and its screen input. Every member is used only on
/// `queue`: a serial queue that applies configuration, `startRunning` and `stopRunning` in the
/// order they were enqueued, so a stop can't remove the input of a start requested after it.
private final class CaptureGraph: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.arkavo.screencapture.session", qos: .userInitiated)

    private let session: AVCaptureSession
    private let videoOutput = AVCaptureVideoDataOutput()
    /// The attached screen input and the capture it was started for.
    private var attached: (input: AVCaptureScreenInput, captureID: UUID)?

    /// The capture whose input is attached, to route frames back to after a failed replacement.
    var attachedCapture: ActiveCapture? {
        dispatchPrecondition(condition: .onQueue(queue))
        return attached.map { ActiveCapture(input: ObjectIdentifier($0.input), id: $0.captureID) }
    }

    init(session: AVCaptureSession) {
        self.session = session
    }

    func configure(
        delegate: any AVCaptureVideoDataOutputSampleBufferDelegate,
        callbackQueue: DispatchQueue
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        session.beginConfiguration()

        // Configure for high quality
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        // Setup video output
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(delegate, queue: callbackQueue)

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
    }

    /// Replaces any attached input with `input` for capture `captureID`, then starts the session
    /// (blocking). Throws `RecorderError.cannotAddInput` if the session can't take `input`; the
    /// attached input then stays attached, the session never having seen it removed.
    func start(with input: AVCaptureScreenInput, captureID: UUID) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        session.beginConfiguration()

        // Swap within one configuration change. Asking `canAddInput` while the old input is
        // still attached would ask about adding a second input, not about the replacement.
        let previous = attached
        if let previous { session.removeInput(previous.input) }
        guard session.canAddInput(input) else {
            if let previous, session.canAddInput(previous.input) {
                session.addInput(previous.input)
            } else {
                attached = nil
            }
            session.commitConfiguration()
            throw RecorderError.cannotAddInput
        }
        session.addInput(input)
        attached = (input, captureID)

        session.commitConfiguration()
        session.startRunning()
    }

    /// Stops the session (blocking), then removes its input.
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        session.stopRunning()

        session.beginConfiguration()
        if let input = attached?.input {
            session.removeInput(input)
            attached = nil
        }
        session.commitConfiguration()
    }
}

// MARK: - Supporting Types

public struct ScreenInfo: Sendable, Identifiable, Hashable {
    public let id: Int
    public let displayID: CGDirectDisplayID
    public let name: String
    public let bounds: CGRect
    public let isPrimary: Bool

    public func hash(into hasher: inout Hasher) {
        hasher.combine(displayID)
    }

    public static func == (lhs: ScreenInfo, rhs: ScreenInfo) -> Bool {
        lhs.displayID == rhs.displayID
    }
}

#endif
