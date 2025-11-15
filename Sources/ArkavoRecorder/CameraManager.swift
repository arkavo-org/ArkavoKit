@preconcurrency import AVFoundation
import CoreGraphics

/// Manages camera capture using AVFoundation
@MainActor
public final class CameraManager: NSObject, Sendable {
    // MARK: - Properties

    private let captureSession: AVCaptureSession
    private var cameraInput: AVCaptureDeviceInput?
    private let videoOutput: AVCaptureVideoDataOutput

    private let outputQueue = DispatchQueue(label: "com.arkavo.cameracapture")

    nonisolated(unsafe) public var onFrame: (@Sendable (CMSampleBuffer) -> Void)?

    // MARK: - Initialization

    public override init() {
        self.captureSession = AVCaptureSession()
        self.videoOutput = AVCaptureVideoDataOutput()

        super.init()

        setupSession()
    }

    // MARK: - Setup

    private func setupSession() {
        captureSession.beginConfiguration()

        // Configure for 1080p
        if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
        } else if captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
        }

        // Setup video output
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.commitConfiguration()
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

        captureSession.beginConfiguration()

        // Remove existing input if any
        if let existingInput = cameraInput {
            captureSession.removeInput(existingInput)
        }

        // Add new input
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            cameraInput = input
        } else {
            captureSession.commitConfiguration()
            throw RecorderError.cannotAddInput
        }

        captureSession.commitConfiguration()

        // Start the session
        Task {
            captureSession.startRunning()
        }
        #else
        throw RecorderError.cameraUnavailable
        #endif
    }

    /// Stops camera capture
    public func stopCapture() {
        Task {
            captureSession.stopRunning()

            captureSession.beginConfiguration()
            if let input = cameraInput {
                captureSession.removeInput(input)
                cameraInput = nil
            }
            captureSession.commitConfiguration()
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
        return captureSession
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Forward frame to handler - calling directly on callback queue
        // CMSampleBuffer is not Sendable but we handle it synchronously
        onFrame?(sampleBuffer)
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
