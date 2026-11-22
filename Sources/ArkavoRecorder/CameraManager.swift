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

    private struct FrameDeliveryState: Sendable {
        var activeCaptureID: UUID? = nil
        var firstFrameDelivered: Bool = false
    }

    private let frameStateLock = OSAllocatedUnfairLock(initialState: FrameDeliveryState())

    /// Continuation for async first-frame signaling
    private var firstFrameWaiter: (captureID: UUID, continuation: CheckedContinuation<Void, any Error>)?
    private var hasDeliveredFirstFrame: Bool = false

    // MARK: - Initialization

    public override init() {
        self.graph = CameraSessionGraph(session: AVCaptureSession())

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

    /// Starts camera capture with a specific device
    public func startCapture(with deviceID: String?) throws {
        #if os(macOS) || os(iOS)
        let request = try prepareStartRequest(with: deviceID)
        enqueueStart(request)
        #else
        throw RecorderError.cameraUnavailable
        #endif
    }

    /// Starts camera capture and waits for the first frame to be delivered
    /// This ensures the camera is actually producing frames before returning
    public func startCaptureAndWaitForFirstFrame(with deviceID: String?) async throws {
        #if os(macOS) || os(iOS)
        let request = try prepareStartRequest(with: deviceID)
        let captureID = request.captureID

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    // Never overwrite a pending continuation without resuming it first
                    endFirstFrameWait()
                    firstFrameWaiter = (captureID, continuation)
                }

                enqueueStart(request) { [weak self] result in
                    guard case .failure(let error) = result else { return }
                    Task { @MainActor [weak self] in
                        self?.endFirstFrameWait(of: captureID, throwing: error)
                    }
                }
            }
        } onCancel: { [weak self] in
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

        // Reset first-frame tracking and end any stale waiter before queueing start
        hasDeliveredFirstFrame = false
        endFirstFrameWait()
        frameStateLock.withLock {
            $0 = FrameDeliveryState(activeCaptureID: captureID, firstFrameDelivered: false)
        }

        return StartRequest(input: input, captureID: captureID)
    }

    private func enqueueStart(
        _ request: StartRequest,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void = { _ in }
    ) {
        let graph = graph
        let frameStateLock = frameStateLock
        graph.queue.async {
            do {
                try graph.start(with: request.input)
                completion(.success(()))
            } catch {
                frameStateLock.withLock { state in
                    if state.activeCaptureID == request.captureID {
                        state = FrameDeliveryState()
                    }
                }
                completion(.failure(error))
            }
        }
    }
    #endif

    private func endFirstFrameWait(of captureID: UUID? = nil, throwing error: any Error = CancellationError()) {
        guard let waiter = firstFrameWaiter, captureID == nil || waiter.captureID == captureID else { return }
        firstFrameWaiter = nil
        waiter.continuation.resume(throwing: error)
    }

    /// Signal that first frame was received (called once per capture)
    private func signalFirstFrame(captureID: UUID) {
        let isCurrent = frameStateLock.withLock { $0.activeCaptureID == captureID }
        guard isCurrent, !hasDeliveredFirstFrame else { return }
        hasDeliveredFirstFrame = true
        guard let waiter = firstFrameWaiter, waiter.captureID == captureID else { return }
        firstFrameWaiter = nil
        waiter.continuation.resume()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Forward frame to handler using lock-protected snapshot
        let handler = onFrameLock.withLock { $0 }
        handler?(sampleBuffer)

        // Hop to MainActor only once for the first frame of each capture
        let firstFrameCaptureID: UUID? = frameStateLock.withLock { state in
            guard let captureID = state.activeCaptureID, !state.firstFrameDelivered else {
                return nil
            }
            state.firstFrameDelivered = true
            return captureID
        }

        if let captureID = firstFrameCaptureID {
            Task { @MainActor [weak self] in
                self?.signalFirstFrame(captureID: captureID)
            }
        }
    }
}

// MARK: - Serialized Capture Session Graph

/// Owns all mutable `AVCaptureSession` operations on a single serial queue so configuration,
/// `startRunning`, and `stopRunning` never race across threads.
private final class CameraSessionGraph: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.arkavo.cameracapture.session", qos: .userInitiated)
    let session: AVCaptureSession

    private let videoOutput = AVCaptureVideoDataOutput()
    private var cameraInput: AVCaptureDeviceInput?

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

    func start(with input: AVCaptureDeviceInput) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        session.beginConfiguration()

        // Remove existing input and clear reference before checking canAddInput
        if let existingInput = cameraInput {
            session.removeInput(existingInput)
            cameraInput = nil
        }

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecorderError.cannotAddInput
        }

        session.addInput(input)
        cameraInput = input
        session.commitConfiguration()

        session.startRunning()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        if session.isRunning {
            session.stopRunning()
        }

        session.beginConfiguration()
        if let input = cameraInput {
            session.removeInput(input)
            cameraInput = nil
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
