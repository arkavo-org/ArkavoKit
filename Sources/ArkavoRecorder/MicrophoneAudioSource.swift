@preconcurrency import AVFoundation
import CoreAudio
import os

/// Audio source for capturing microphone input
public final class MicrophoneAudioSource: NSObject, AudioSource, Sendable {
    // MARK: - AudioSource Protocol

    public let sourceID: String
    public var sourceName: String {
        if let deviceName = state.withLockUnchecked({ $0.audioInput?.device.localizedName }) {
            return "Microphone: \(deviceName)"
        }
        return "Microphone"
    }

    public var format: AudioFormat {
        // Note: On iOS, AVCaptureAudioDataOutput does not expose `audioSettings`; the actual capture format
        // may be device-dependent. We target 48kHz/16-bit/stereo for downstream processing.
        AudioFormat(sampleRate: 48000.0, channels: 2, bitDepth: 16, formatID: kAudioFormatLinearPCM)
    }

    public var isActive: Bool {
        captureSession.isRunning
    }

    public var onSample: ((CMSampleBuffer) -> Void)? {
        get { state.withLockUnchecked { $0.onSample } }
        set { state.withLockUnchecked { $0.onSample = newValue } }
    }

    // MARK: - Properties

    private struct SharedState {
        var audioInput: AVCaptureDeviceInput?
        var onSample: ((CMSampleBuffer) -> Void)?
        var onLevelUpdate: (@Sendable (Float) -> Void)?
    }

    private let state = OSAllocatedUnfairLock<SharedState>(uncheckedState: SharedState())
    private let captureSession: AVCaptureSession
    private let audioOutput: AVCaptureAudioDataOutput

    private let sessionQueue = DispatchQueue(label: "com.arkavo.microphone.session.\(UUID().uuidString)")
    private let outputQueue = DispatchQueue(label: "com.arkavo.microphone.\(UUID().uuidString)")

    public var onLevelUpdate: (@Sendable (Float) -> Void)? {
        get { state.withLockUnchecked { $0.onLevelUpdate } }
        set { state.withLockUnchecked { $0.onLevelUpdate = newValue } }
    }

    private let deviceID: String?

    // MARK: - Initialization

    /// Initialize with optional specific device ID
    /// - Parameters:
    ///   - sourceID: Unique identifier for this audio source
    ///   - deviceID: Optional AVCaptureDevice uniqueID for specific microphone, nil for default
    public init(sourceID: String, deviceID: String? = nil) {
        self.sourceID = sourceID
        self.deviceID = deviceID
        self.captureSession = AVCaptureSession()
        self.audioOutput = AVCaptureAudioDataOutput()

        super.init()

        setupSession()
    }

    // MARK: - Setup

    private func setupSession() {
        let session = captureSession
        let output = audioOutput
        let queue = outputQueue
        sessionQueue.sync {
            session.beginConfiguration()

            // Setup audio output
            // On macOS, we can configure explicit Linear PCM settings. On iOS, `audioSettings` is unavailable.
            #if os(macOS)
            // Output format: 16-bit Linear PCM, 48kHz, stereo
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            output.audioSettings = audioSettings
            #endif

            output.setSampleBufferDelegate(self, queue: queue)

            if session.canAddOutput(output) {
                session.addOutput(output)
            }

            session.commitConfiguration()
        }
    }

    // MARK: - AudioSource Protocol Methods

    public func start() async throws {
        #if os(macOS) || os(iOS)
        let targetDeviceID = deviceID
        let session = captureSession

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sessionQueue.async { [self, session, targetDeviceID] in
                // Find the microphone device
                let device: AVCaptureDevice?
                if let targetDeviceID {
                    device = AVCaptureDevice(uniqueID: targetDeviceID)
                } else {
                    device = AVCaptureDevice.default(for: .audio)
                }

                guard let microphone = device else {
                    continuation.resume(throwing: RecorderError.microphoneUnavailable)
                    return
                }

                // Create input on sessionQueue so it never crosses concurrency domains
                let input: AVCaptureDeviceInput
                do {
                    input = try AVCaptureDeviceInput(device: microphone)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                session.beginConfiguration()

                // Remove existing input if any
                if let existingInput = state.withLockUnchecked({ $0.audioInput }) {
                    session.removeInput(existingInput)
                }

                // Add new input
                if session.canAddInput(input) {
                    session.addInput(input)
                    state.withLockUnchecked { $0.audioInput = input }
                } else {
                    session.commitConfiguration()
                    continuation.resume(throwing: RecorderError.cannotAddInput)
                    return
                }

                session.commitConfiguration()

                // Start the session
                session.startRunning()
                continuation.resume()
            }
        }

        print("🎤 MicrophoneAudioSource [\(sourceID)] started: \(sourceName)")
        #else
        throw RecorderError.microphoneUnavailable
        #endif
    }

    public func stop() async throws {
        let session = captureSession
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self, session] in
                session.stopRunning()

                session.beginConfiguration()
                if let input = state.withLockUnchecked({ state -> AVCaptureDeviceInput? in
                    defer { state.audioInput = nil }
                    return state.audioInput
                }) {
                    session.removeInput(input)
                }
                session.commitConfiguration()
                continuation.resume()
            }
        }

        print("🎤 MicrophoneAudioSource [\(sourceID)] stopped")
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
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension MicrophoneAudioSource: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Calculate audio level from sample buffer
        let level = Self.calculateAudioLevel(from: sampleBuffer)

        let (levelCallback, sampleCallback) = state.withLockUnchecked { state in
            (state.onLevelUpdate, state.onSample)
        }

        // Forward directly on callback queue
        levelCallback?(level)
        sampleCallback?(sampleBuffer)
    }

    nonisolated static func calculateAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        AudioManager.calculateAudioLevel(from: sampleBuffer)
    }
}
