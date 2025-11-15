#if os(macOS)
@preconcurrency import AVFoundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// Manages screen capture using AVFoundation
@MainActor
public final class ScreenCaptureManager: NSObject, Sendable {
    // MARK: - Properties

    private let captureSession: AVCaptureSession
    private var screenInput: AVCaptureScreenInput?
    private let videoOutput: AVCaptureVideoDataOutput

    private let outputQueue = DispatchQueue(label: "com.arkavo.screencapture")

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

        // Configure for high quality
        if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
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

    /// Starts screen capture for the main display
    public func startCapture() throws {
        #if os(macOS)
        guard let mainDisplay = CGMainDisplayID() as CGDirectDisplayID? else {
            throw RecorderError.screenCaptureUnavailable
        }

        // Create screen input
        guard let input = AVCaptureScreenInput(displayID: mainDisplay) else {
            throw RecorderError.screenCaptureUnavailable
        }

        input.minFrameDuration = CMTime(value: 1, timescale: 30) // 30 fps
        input.capturesCursor = true
        input.capturesMouseClicks = false

        captureSession.beginConfiguration()

        // Remove existing input if any
        if let existingInput = screenInput {
            captureSession.removeInput(existingInput)
        }

        // Add new input
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            screenInput = input
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
        throw RecorderError.screenCaptureUnavailable
        #endif
    }

    /// Stops screen capture
    public func stopCapture() {
        Task {
            captureSession.stopRunning()

            captureSession.beginConfiguration()
            if let input = screenInput {
                captureSession.removeInput(input)
                screenInput = nil
            }
            captureSession.commitConfiguration()
        }
    }

    /// Returns available screens
    public static func availableScreens() -> [ScreenInfo] {
        #if os(macOS)
        let displays = NSScreen.screens
        return displays.enumerated().map { index, screen in
            ScreenInfo(
                id: index,
                name: screen.localizedName,
                bounds: screen.frame
            )
        }
        #else
        return []
        #endif
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension ScreenCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
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

public struct ScreenInfo: Sendable {
    public let id: Int
    public let name: String
    public let bounds: CGRect
}

#endif
