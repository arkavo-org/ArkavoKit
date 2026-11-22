@preconcurrency import AVFoundation
import CoreGraphics
import os

/// Manages camera capture using AVFoundation
@MainActor
public final class CameraManager: NSObject, Sendable {
    // MARK: - Properties

    private let graph: CameraSessionGraph
    private let outputQueue = DispatchQueue(label: "com.arkavo.cameracapture")

    private let onFrameLock = OSAllocatedUnfairLock<(@Sendable (CMSampleBuffer) -> Void)?>(initialState: nil)

    nonisolated public var onFrame: (@Sendable (CMSampleBuffer) -> Void)? {
        get { onFrameLock.withLock { $0 } }
        set { onFrameLock.withLock { $0 = newValue } }
    }

    /// Called on the main actor when `startCapture(with:)` cannot attach its input asynchronously
    /// on the session queue (e.g. `RecorderError.cannotAddInput`). The previously attached input,
    /// if any, keeps capturing. `startCaptureAndWaitForFirstFrame` throws instead.
    public var onCaptureError: (@MainActor (any Error) -> Void)?

    private struct FrameDeliveryState: Sendable {
        var pendingCaptureID: UUID? = nil
        var cancelledPendingCaptureID: UUID? = nil
        var activeCaptureID: UUID? = nil
        var activeInput: ObjectIdentifier? = nil
        var acceptingFrames: Bool = false
        var firstFrameDelivered: Bool = false
    }

    private let frameStateLock = OSAllocatedUnfairLock(initialState: FrameDeliveryState())

    /// Continuation for async first-frame signaling
    private var firstFrameWaiter: (captureID: UUID, continuation: CheckedContinuation<Void, any Error>)?
    private var hasDeliveredFirstFrame: Bool = false

    // MARK: - Initialization

    public override convenience init() {
        self.init(captureSession: AVCaptureSession())
    }

    init(captureSession: AVCaptureSession) {
        self.graph = CameraSessionGraph(session: captureSession)

        super.init()

        let graph = graph
        let outputQueue = outputQueue
        graph.queue.async { [self] in
            graph.configure(delegate: self, callbackQueue: outputQueue)
        }
    }

    // MARK: - Public Methods

    /// Requests camera permission
    public static func requestPermission() async -> Bool {
        #if os(macOS) || os(iOS)
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
        #else
        return false
        #endif
    }

    /// Starts camera capture with the default device
    public func startCapture() throws {
        try startCapture(with: nil)
    }

    /// Starts camera capture with a specific device.
    ///
    /// Device lookup and `AVCaptureDeviceInput` creation run synchronously (throwing
    /// `RecorderError.cameraUnavailable` or an `AVError` immediately). Session reconfiguration
    /// and `startRunning()` run asynchronously on `graph.queue` so the main actor never blocks
    /// on `AVCaptureSession`; if attaching the input fails asynchronously (e.g.
    /// `RecorderError.cannotAddInput`), the previously attached input keeps capturing and
    /// `onCaptureError` receives the error.
    public func startCapture(with deviceID: String?) throws {
        #if os(macOS) || os(iOS)
        let request = try prepareStartRequest(with: deviceID)
        enqueueStart(request, reportsFailure: true)
        #else
        throw RecorderError.cameraUnavailable
        #endif
    }

    /// Starts camera capture and waits for the first frame to be delivered
    /// This ensures the camera is actually producing frames before returning
    public func startCaptureAndWaitForFirstFrame(with deviceID: String?) async throws {
        #if os(macOS) || os(iOS)
        try Task.checkCancellation()
        let request = try prepareStartRequest(with: deviceID)
        let captureID = request.captureID
        let frameStateLock = frameStateLock

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    restorePendingSwitch(captureID: captureID)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Never overwrite a pending continuation without resuming it first
                endFirstFrameWait()
                firstFrameWaiter = (captureID, continuation)

                enqueueStart(request, reportsFailure: false) { [weak self] result in
                    guard case .failure(let error) = result else { return }
                    Task { @MainActor [weak self] in
                        self?.endFirstFrameWait(of: captureID, throwing: error)
                    }
                }
            }
        } onCancel: { [weak self] in
            frameStateLock.withLock { state in
                if state.pendingCaptureID == captureID, state.activeCaptureID == nil {
                    state.cancelledPendingCaptureID = captureID
                }
            }
            Task { @MainActor [weak self] in
                self?.endFirstFrameWait(of: captureID)
            }
        }

        print("📷 [CameraManager] First frame delivered, capture ready")
        #else
        throw RecorderError.cameraUnavailable
        #endif
    }

    /// Stops camera capture, cancelling any pending first-frame wait and serializing session teardown.
    public func stopCapture() {
        frameStateLock.withLock { $0 = FrameDeliveryState() }
        hasDeliveredFirstFrame = false
        endFirstFrameWait()

        let graph = graph
        graph.queue.async {
            graph.stop()
        }
    }

    /// Returns available cameras, including Continuity Camera when available
    public static func availableCameras() -> [CameraInfo] {
        #if os(macOS) || os(iOS)
            var deviceTypes: [AVCaptureDevice.DeviceType] = [
                .builtInWideAngleCamera,
                .external
            ]

            if #available(macOS 14.0, iOS 17.0, *) {
                deviceTypes.append(.continuityCamera)
            }

            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: deviceTypes,
                mediaType: .video,
                position: .unspecified
            )

            return discoverySession.devices.map { device in
                CameraInfo(
                    id: device.uniqueID,
                    name: device.localizedName,
                    position: device.position,
                    transport: transport(for: device)
                )
            }
        #else
            return []
        #endif
    }

    /// Returns the preferred built-in front camera identifier
    public static func defaultCameraIdentifier() -> String? {
        #if os(macOS) || os(iOS)
            if let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
                return front.uniqueID
            }
            if let any = AVCaptureDevice.default(for: .video) {
                return any.uniqueID
            }
            return nil
        #else
            return nil
        #endif
    }

    private static func transport(for device: AVCaptureDevice) -> CameraTransport {
        #if os(macOS) || os(iOS)
            if #available(macOS 14.0, iOS 17.0, *), device.deviceType == .continuityCamera {
                return .continuity
            }

            if device.position == .unspecified {
                return .external
            }

            return .builtIn
        #else
            return .unknown
        #endif
    }

    /// Get the capture session for preview
    public func getPreviewSession() -> AVCaptureSession {
        return graph.session
    }

    // MARK: - Private Capture Lifecycle

    private struct StartRequest: @unchecked Sendable {
        let input: AVCaptureDeviceInput
        let captureID: UUID
    }

    #if os(macOS) || os(iOS)
    private func prepareStartRequest(with deviceID: String?) throws -> StartRequest {
        // Find the camera device
        let device: AVCaptureDevice?
        if let deviceID = deviceID {
            device = AVCaptureDevice(uniqueID: deviceID)
        } else {
            device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video)
        }

        guard let camera = device else {
            throw RecorderError.cameraUnavailable
        }

        // Create input
        let input = try AVCaptureDeviceInput(device: camera)
        let captureID = UUID()

        // Pause frame acceptance until the new input is committed on `graph.queue`.
        beginInputSwitch(captureID: captureID)

        return StartRequest(input: input, captureID: captureID)
    }

    private enum PendingStartStatus {
        case proceed
        case cancelled
        case superseded
    }

    private func restorePendingSwitch(captureID: UUID) {
        let graph = graph
        let frameStateLock = frameStateLock
        graph.queue.async {
            _ = Self.restoreCaptureAfterFailure(
                failedCaptureID: captureID,
                restored: graph.attachedCapture,
                in: frameStateLock
            )
        }
    }

    private func enqueueStart(
        _ request: StartRequest,
        reportsFailure: Bool,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void = { _ in }
    ) {
        let graph = graph
        let frameStateLock = frameStateLock
        graph.queue.async { [weak self] in
            let status: PendingStartStatus = frameStateLock.withLock { state in
                guard state.pendingCaptureID == request.captureID else { return .superseded }
                if state.cancelledPendingCaptureID == request.captureID { return .cancelled }
                return .proceed
            }
            switch status {
            case .superseded:
                completion(.failure(CancellationError()))
                return
            case .cancelled:
                _ = Self.restoreCaptureAfterFailure(
                    failedCaptureID: request.captureID,
                    restored: graph.attachedCapture,
                    in: frameStateLock
                )
                completion(.failure(CancellationError()))
                return
            case .proceed:
                break
            }

            do {
                try graph.attachInput(request.input, captureID: request.captureID)
                Self.activateCapture(
                    captureID: request.captureID,
                    inputID: ObjectIdentifier(request.input),
                    in: frameStateLock
                )
                graph.startRunningIfAttached(captureID: request.captureID)
                completion(.success(()))
            } catch {
                let wasCurrent = Self.restoreCaptureAfterFailure(
                    failedCaptureID: request.captureID,
                    restored: graph.attachedCapture,
                    in: frameStateLock
                )
                if wasCurrent && reportsFailure {
                    Task { @MainActor [weak self] in
                        self?.onCaptureError?(error)
                    }
                }
                completion(.failure(error))
            }
        }
    }
    #endif

    /// Returns once every session change requested before the call has run on the session queue.
    func waitForSessionQueue() async {
        let queue = graph.queue
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// Disables frame acceptance and clears any previous waiter while switching to `captureID`.
    func beginInputSwitch(captureID: UUID) {
        hasDeliveredFirstFrame = false
        endFirstFrameWait()
        frameStateLock.withLock {
            $0 = FrameDeliveryState(
                pendingCaptureID: captureID,
                cancelledPendingCaptureID: nil,
                activeCaptureID: nil,
                activeInput: nil,
                acceptingFrames: false,
                firstFrameDelivered: false
            )
        }
    }

    /// Marks `captureID` as committed and accepting frames from `inputID`.
    nonisolated func commitInputSwitch(captureID: UUID, inputID: ObjectIdentifier?) {
        Self.activateCapture(captureID: captureID, inputID: inputID, in: frameStateLock)
    }

    private nonisolated static func activateCapture(
        captureID: UUID,
        inputID: ObjectIdentifier?,
        in frameStateLock: OSAllocatedUnfairLock<FrameDeliveryState>
    ) {
        frameStateLock.withLock { state in
            guard state.pendingCaptureID == captureID else { return }
            state.cancelledPendingCaptureID = nil
            state.activeCaptureID = captureID
            state.activeInput = inputID
            state.acceptingFrames = true
            state.firstFrameDelivered = false
        }
    }

    @discardableResult
    private nonisolated static func restoreCaptureAfterFailure(
        failedCaptureID: UUID,
        restored: (input: ObjectIdentifier, captureID: UUID)?,
        in frameStateLock: OSAllocatedUnfairLock<FrameDeliveryState>
    ) -> Bool {
        frameStateLock.withLock { state in
            guard state.pendingCaptureID == failedCaptureID else { return false }
            if let restored {
                state = FrameDeliveryState(
                    pendingCaptureID: restored.captureID,
                    cancelledPendingCaptureID: nil,
                    activeCaptureID: restored.captureID,
                    activeInput: restored.input,
                    acceptingFrames: true,
                    firstFrameDelivered: true
                )
            } else {
                state = FrameDeliveryState()
            }
            return true
        }
    }

    /// Tests: awaits the first accepted frame for `captureID`.
    func waitForFirstFrameForTesting(captureID: UUID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                endFirstFrameWait()
                firstFrameWaiter = (captureID, continuation)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.endFirstFrameWait(of: captureID)
            }
        }
    }

    private func endFirstFrameWait(of captureID: UUID? = nil, throwing error: any Error = CancellationError()) {
        guard let waiter = firstFrameWaiter, captureID == nil || waiter.captureID == captureID else { return }
        firstFrameWaiter = nil
        waiter.continuation.resume(throwing: error)
    }

    /// Signal that first frame was received (called once per capture)
    private func signalFirstFrame(captureID: UUID) {
        let isCurrent = frameStateLock.withLock { $0.acceptingFrames && $0.activeCaptureID == captureID }
        guard isCurrent, !hasDeliveredFirstFrame else { return }
        hasDeliveredFirstFrame = true
        guard let waiter = firstFrameWaiter, waiter.captureID == captureID else { return }
        firstFrameWaiter = nil
        waiter.continuation.resume()
    }

    nonisolated func handleOutputFrame(_ sampleBuffer: CMSampleBuffer, fromInput inputID: ObjectIdentifier?) {
        let decision: (accept: Bool, firstFrameCaptureID: UUID?) = frameStateLock.withLock { state in
            guard state.acceptingFrames, let captureID = state.activeCaptureID else {
                return (false, nil)
            }
            // Reject both mismatched inputs and nil inputID (empty inputPorts on a torn-down
            // AVCaptureConnection) whenever a concrete activeInput is expected.
            if let expectedInput = state.activeInput, inputID != expectedInput {
                return (false, nil)
            }
            if !state.firstFrameDelivered {
                state.firstFrameDelivered = true
                return (true, captureID)
            }
            return (true, nil)
        }

        guard decision.accept else { return }

        // Forward frame to handler using lock-protected snapshot
        let handler = onFrameLock.withLock { $0 }
        handler?(sampleBuffer)

        // Hop to MainActor only once for the first frame of each capture
        if let captureID = decision.firstFrameCaptureID {
            Task { @MainActor [weak self] in
                self?.signalFirstFrame(captureID: captureID)
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let inputID = connection.inputPorts.first.map { ObjectIdentifier($0.input) }
        handleOutputFrame(sampleBuffer, fromInput: inputID)
    }
}

// MARK: - Serialized Capture Session Graph

/// Owns all mutable `AVCaptureSession` operations on a single serial queue so configuration,
/// `startRunning`, and `stopRunning` never race across threads.
private final class CameraSessionGraph: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.arkavo.cameracapture.session", qos: .userInitiated)
    let session: AVCaptureSession

    private let videoOutput = AVCaptureVideoDataOutput()
    private var attached: (input: AVCaptureDeviceInput, captureID: UUID)?

    var attachedCapture: (input: ObjectIdentifier, captureID: UUID)? {
        dispatchPrecondition(condition: .onQueue(queue))
        return attached.map { (ObjectIdentifier($0.input), $0.captureID) }
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

        // Configure for 1080p
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
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

    func attachInput(_ input: AVCaptureDeviceInput, captureID: UUID) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        session.beginConfiguration()

        // Swap within one configuration block; restore the previous input if adding the new one fails.
        let previous = attached
        if let previous {
            session.removeInput(previous.input)
        }

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
    }

    func startRunningIfAttached(captureID: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard attached?.captureID == captureID else { return }
        if !session.isRunning {
            session.startRunning()
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        if session.isRunning {
            session.stopRunning()
        }

        session.beginConfiguration()
        if let input = attached?.input {
            session.removeInput(input)
            attached = nil
        }
        session.commitConfiguration()
    }
}

// MARK: - Supporting Types

public struct CameraInfo: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let position: AVCaptureDevice.Position
    public let transport: CameraTransport

    public var displayName: String {
        switch position {
        case .front:
            return "\(name) (Front)"
        case .back:
            return "\(name) (Back)"
        default:
            return name
        }
    }
}

public enum CameraTransport: String, Sendable {
    case builtIn
    case continuity
    case external
    case usb
    case bluetooth
    case virtual
    case remote
    case unknown

    public var displayName: String {
        switch self {
        case .builtIn:
            return "Built-In"
        case .continuity:
            return "Continuity"
        case .external:
            return "External"
        case .usb:
            return "USB-C"
        case .bluetooth:
            return "Bluetooth"
        case .virtual:
            return "Virtual"
        case .remote:
            return "Remote"
        case .unknown:
            return "Unknown"
        }
    }
}
