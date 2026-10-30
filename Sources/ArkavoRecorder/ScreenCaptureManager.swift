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
    nonisolated(unsafe) var onFrameForCapture: (@Sendable (CMSampleBuffer, UUID) -> Void)?
    private struct ActiveCapture {
        let input: ObjectIdentifier
        let id = UUID()
    }
    private let activeCapture = OSAllocatedUnfairLock<ActiveCapture?>(initialState: nil)

    nonisolated func isCurrentCapture(_ id: UUID) -> Bool {
        activeCapture.withLock { $0?.id == id }
    }

    /// The `startCaptureAndWaitForFirstFrame` call waiting for its capture's first frame.
    /// A frame of that capture resumes it; a stop or a newer start ends it with `CancellationError`.
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
    /// `RecorderError.screenCaptureUnavailable` when the display can't be captured.
    public func startCapture(displayID: CGDirectDisplayID? = nil) throws {
        #if os(macOS)
        let request = try beginCapture(displayID: displayID)
        enqueueStart(request)
        #else
        throw RecorderError.screenCaptureUnavailable
        #endif
    }

    /// Starts screen capture and waits for the first frame to be delivered
    /// This ensures the screen capture is actually producing frames before returning
    ///
    /// Throws `RecorderError.cannotAddInput` if the session can't take the display's input, and
    /// `CancellationError` if `stopCapture` or another start replaces this capture before its
    /// first frame arrives.
    public func startCaptureAndWaitForFirstFrame(displayID: CGDirectDisplayID? = nil) async throws {
        #if os(macOS)
        let request = try beginCapture(displayID: displayID)

        // Throw if the session can't take the input, rather than wait for a frame that won't come.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            enqueueStart(request) { continuation.resume(with: $0) }
        }

        // A stop or a newer start while this one was queued has replaced it: no frame will come.
        guard isCurrentCapture(request.captureID) else { throw CancellationError() }

        // Wait for first frame
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if hasDeliveredFirstFrame {
                // Already got a frame
                continuation.resume()
            } else {
                // Resumed when this capture's first frame arrives, or ended when it's replaced
                endFirstFrameWait()
                firstFrameWaiter = (request.captureID, continuation)
            }
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

        let capture = ActiveCapture(input: ObjectIdentifier(input))
        activeCapture.withLock { $0 = capture }

        // Reset first frame tracking; a wait for the replaced capture's frame can't succeed now.
        hasDeliveredFirstFrame = false
        endFirstFrameWait()
        return StartRequest(input: input, captureID: capture.id)
    }

    /// Ends a pending first-frame wait whose capture is no longer current.
    private func endFirstFrameWait() {
        guard let waiter = firstFrameWaiter else { return }
        firstFrameWaiter = nil
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Attaches the request's input and starts the session on the session queue. If the session
    /// can't take the input, frames stay unrouted until the next start.
    private func enqueueStart(
        _ request: StartRequest,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void = { _ in }
    ) {
        let graph = graph, activeCapture = activeCapture
        graph.queue.async {
            do {
                try graph.start(with: request.input)
                completion(.success(()))
            } catch {
                activeCapture.withLock { if $0?.id == request.captureID { $0 = nil } }
                print("🖥️ [ScreenCaptureManager] Screen capture couldn't start: \(error)")
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

/// The capture session, its video output and its screen input. Every member is used only on
/// `queue`: a serial queue that applies configuration, `startRunning` and `stopRunning` in the
/// order they were enqueued, so a stop can't remove the input of a start requested after it.
private final class CaptureGraph: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.arkavo.screencapture.session", qos: .userInitiated)

    private let session: AVCaptureSession
    private let videoOutput = AVCaptureVideoDataOutput()
    private var screenInput: AVCaptureScreenInput?

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

    /// Replaces any attached input with `input`, then starts the session (blocking).
    func start(with input: AVCaptureScreenInput) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        session.beginConfiguration()

        // Remove existing input if any
        if let existingInput = screenInput {
            session.removeInput(existingInput)
            screenInput = nil
        }

        // Add new input
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecorderError.cannotAddInput
        }
        session.addInput(input)
        screenInput = input

        session.commitConfiguration()
        session.startRunning()
    }

    /// Stops the session (blocking), then removes its input.
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        session.stopRunning()

        session.beginConfiguration()
        if let input = screenInput {
            session.removeInput(input)
            screenInput = nil
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
