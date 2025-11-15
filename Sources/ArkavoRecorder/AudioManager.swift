@preconcurrency import AVFoundation
import CoreAudio

/// Manages audio capture from microphone
@MainActor
public final class AudioManager: NSObject, Sendable {
    // MARK: - Properties

    private let captureSession: AVCaptureSession
    private var audioInput: AVCaptureDeviceInput?
    private let audioOutput: AVCaptureAudioDataOutput

    private let outputQueue = DispatchQueue(label: "com.arkavo.audiocapture")

    nonisolated(unsafe) public var onSample: (@Sendable (CMSampleBuffer) -> Void)?
    nonisolated(unsafe) public var onLevelUpdate: (@Sendable (Float) -> Void)?

    private var levelTimer: Timer?

    // MARK: - Initialization

    public override init() {
        self.captureSession = AVCaptureSession()
        self.audioOutput = AVCaptureAudioDataOutput()

        super.init()

        setupSession()
    }

    // MARK: - Setup

    private func setupSession() {
        captureSession.beginConfiguration()

        // Setup audio output
        // On macOS, we can configure Linear PCM format explicitly.
        // On iOS, `audioSettings` is unavailable; rely on default format and convert if needed downstream.
        #if os(macOS)
        // Configure to output 16-bit Linear PCM at 44.1kHz stereo
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        audioOutput.audioSettings = audioSettings
        #endif
        audioOutput.setSampleBufferDelegate(self, queue: outputQueue)

        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }

        captureSession.commitConfiguration()
    }

    // MARK: - Public Methods

    /// Requests microphone permission
    public static func requestPermission() async -> Bool {
        #if os(macOS) || os(iOS)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
        #else
        return false
        #endif
    }

    /// Starts audio capture with the default microphone
    public func startCapture() throws {
        try startCapture(with: nil)
    }

    /// Starts audio capture with a specific device
    public func startCapture(with deviceID: String?) throws {
        #if os(macOS) || os(iOS)
        // Find the microphone device
        let device: AVCaptureDevice?
        if let deviceID = deviceID {
            device = AVCaptureDevice(uniqueID: deviceID)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }

        guard let microphone = device else {
            throw RecorderError.microphoneUnavailable
        }

        // Create input
        let input = try AVCaptureDeviceInput(device: microphone)

        captureSession.beginConfiguration()

        // Remove existing input if any
        if let existingInput = audioInput {
            captureSession.removeInput(existingInput)
        }

        // Add new input
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            audioInput = input
        } else {
            captureSession.commitConfiguration()
            throw RecorderError.cannotAddInput
        }

        captureSession.commitConfiguration()

        // Start the session
        Task {
            captureSession.startRunning()
        }

        // Start monitoring audio levels
        startLevelMonitoring()
        #else
        throw RecorderError.microphoneUnavailable
        #endif
    }

    /// Stops audio capture
    public func stopCapture() {
        Task {
            captureSession.stopRunning()

            captureSession.beginConfiguration()
            if let input = audioInput {
                captureSession.removeInput(input)
                audioInput = nil
            }
            captureSession.commitConfiguration()
        }

        stopLevelMonitoring()
    }

    /// Returns available microphones
    public static func availableMicrophones() -> [AudioDeviceInfo] {
        #if os(macOS) || os(iOS)
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        return discoverySession.devices.map { device in
            AudioDeviceInfo(
                id: device.uniqueID,
                name: device.localizedName
            )
        }
        #else
        return []
        #endif
    }

    // MARK: - Level Monitoring

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                // Get current audio level from the input device
                if let audioInput = self.audioInput {
                    let level = self.getCurrentAudioLevel(from: audioInput.device)
                    self.onLevelUpdate?(level)
                }
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func getCurrentAudioLevel(from device: AVCaptureDevice) -> Float {
        // This is a simplified implementation
        // In production, you'd want to calculate this from the actual audio samples
        return 0.0
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Calculate audio level from sample buffer
        let level = calculateAudioLevel(from: sampleBuffer)

        // Forward directly on callback queue
        // CMSampleBuffer is not Sendable but we handle it synchronously
        onLevelUpdate?(level)
        onSample?(sampleBuffer)
    }

    private nonisolated func calculateAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0.0
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let dataPointer = dataPointer else {
            return 0.0
        }

        // Calculate RMS (Root Mean Square) for audio level
        var sum: Float = 0.0
        let samples = length / MemoryLayout<Int16>.size

        dataPointer.withMemoryRebound(to: Int16.self, capacity: samples) { ptr in
            for i in 0..<samples {
                let sample = Float(ptr[i]) / Float(Int16.max)
                sum += sample * sample
            }
        }

        let rms = sqrt(sum / Float(samples))
        return min(1.0, rms * 10) // Scale and clamp to 0-1
    }
}

// MARK: - Supporting Types

public struct AudioDeviceInfo: Sendable, Identifiable {
    public let id: String
    public let name: String
}
