@preconcurrency import AVFoundation
import CoreAudio
import os

/// Manages audio capture from microphone
@MainActor
public final class AudioManager: NSObject, Sendable {
    // MARK: - Properties

    private let captureSession: AVCaptureSession
    private let audioOutput: AVCaptureAudioDataOutput

    private let sessionQueue = DispatchQueue(label: "com.arkavo.audiocapture.session")
    private let outputQueue = DispatchQueue(label: "com.arkavo.audiocapture")

    private struct SharedState {
        var audioInput: AVCaptureDeviceInput?
        var onSample: (@Sendable (CMSampleBuffer) -> Void)?
        var onLevelUpdate: (@Sendable (Float) -> Void)?
        var lastSampleTime: ContinuousClock.Instant?
        var emittedIdleZero = false
        var isCapturing = false
        var levelTimer: Timer?
    }

    private let state = OSAllocatedUnfairLock<SharedState>(uncheckedState: SharedState())

    nonisolated public var onSample: (@Sendable (CMSampleBuffer) -> Void)? {
        get { state.withLockUnchecked { $0.onSample } }
        set { state.withLockUnchecked { $0.onSample = newValue } }
    }

    nonisolated public var onLevelUpdate: (@Sendable (Float) -> Void)? {
        get { state.withLockUnchecked { $0.onLevelUpdate } }
        set { state.withLockUnchecked { $0.onLevelUpdate = newValue } }
    }

    // MARK: - Initialization

    public override init() {
        self.captureSession = AVCaptureSession()
        self.audioOutput = AVCaptureAudioDataOutput()

        super.init()

        setupSession()
    }

    deinit {
        let timer = state.withLockUnchecked { state -> Timer? in
            defer { state.levelTimer = nil }
            return state.levelTimer
        }
        if let timer {
            let box = AudioTimerBox(timer: timer)
            if Thread.isMainThread {
                box.invalidate()
            } else {
                DispatchQueue.main.async {
                    box.invalidate()
                }
            }
        }
    }

    // MARK: - Setup

    private func setupSession() {
        let session = captureSession
        let output = audioOutput
        let queue = outputQueue
        sessionQueue.sync {
            session.beginConfiguration()

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
            output.audioSettings = audioSettings
            #endif
            output.setSampleBufferDelegate(self, queue: queue)

            if session.canAddOutput(output) {
                session.addOutput(output)
            }

            session.commitConfiguration()
        }
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
        let session = captureSession

        try sessionQueue.sync {
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
                throw RecorderError.cannotAddInput
            }

            session.commitConfiguration()
        }

        state.withLockUnchecked { state in
            state.isCapturing = true
            state.lastSampleTime = nil
            state.emittedIdleZero = false
        }

        // Start the session serialized on sessionQueue
        sessionQueue.async {
            session.startRunning()
        }

        // Start monitoring audio levels (decays to 0 only when audio stalls)
        startLevelMonitoring()
        #else
        throw RecorderError.microphoneUnavailable
        #endif
    }

    /// Stops audio capture
    public func stopCapture() {
        stopLevelMonitoring()
        state.withLockUnchecked { $0.isCapturing = false }

        let session = captureSession
        sessionQueue.async { [weak self, session] in
            session.stopRunning()

            session.beginConfiguration()
            if let input = self?.state.withLockUnchecked({ state -> AVCaptureDeviceInput? in
                defer { state.audioInput = nil }
                return state.audioInput
            }) {
                session.removeInput(input)
            }
            session.commitConfiguration()
        }
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
        stopLevelMonitoring()

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let callback: (@Sendable (Float) -> Void)? = self.state.withLockUnchecked { state in
                guard state.isCapturing, !state.emittedIdleZero else { return nil }
                // Only emit 0.0 if samples have stalled for > 250ms, never racing with captureOutput.
                if let last = state.lastSampleTime, last.duration(to: .now) < .milliseconds(250) {
                    return nil
                }
                state.emittedIdleZero = true
                return state.onLevelUpdate
            }
            callback?(0.0)
        }
        state.withLockUnchecked { $0.levelTimer = timer }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopLevelMonitoring() {
        let timer = state.withLockUnchecked { state -> Timer? in
            defer { state.levelTimer = nil }
            return state.levelTimer
        }
        timer?.invalidate()
    }
}

private final class AudioTimerBox: @unchecked Sendable {
    let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func invalidate() { timer.invalidate() }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Calculate audio level from sample buffer
        let level = Self.calculateAudioLevel(from: sampleBuffer)

        let (levelCallback, sampleCallback) = state.withLockUnchecked { state -> ((@Sendable (Float) -> Void)?, (@Sendable (CMSampleBuffer) -> Void)?) in
            state.lastSampleTime = .now
            state.emittedIdleZero = false
            return (state.onLevelUpdate, state.onSample)
        }

        // Forward directly on callback queue
        // CMSampleBuffer is not Sendable but we handle it synchronously
        levelCallback?(level)
        sampleCallback?(sampleBuffer)
    }

    nonisolated static func calculateAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0.0
        }

        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        guard totalLength > 0 else {
            return 0.0
        }

        let asbd = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let isFloat: Bool
        let bitsPerChannel: UInt32
        let isBigEndian: Bool
        if let asbd {
            isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            bitsPerChannel = asbd.mBitsPerChannel
            isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        } else {
            isFloat = false
            bitsPerChannel = 16
            isBigEndian = false
        }

        var lengthAtOffset = 0
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        if status == kCMBlockBufferNoErr, let dataPointer, lengthAtOffset >= totalLength {
            let raw = UnsafeRawBufferPointer(start: dataPointer, count: totalLength)
            return computeRMSLevel(from: raw, isFloat: isFloat, bitsPerChannel: bitsPerChannel, isBigEndian: isBigEndian)
        }

        var contiguous = [UInt8](repeating: 0, count: totalLength)
        let copyStatus = contiguous.withUnsafeMutableBytes { dest -> OSStatus in
            guard let base = dest.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: base
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            return 0.0
        }

        return contiguous.withUnsafeBytes { raw in
            computeRMSLevel(from: raw, isFloat: isFloat, bitsPerChannel: bitsPerChannel, isBigEndian: isBigEndian)
        }
    }

    private nonisolated static func computeRMSLevel(
        from raw: UnsafeRawBufferPointer,
        isFloat: Bool,
        bitsPerChannel: UInt32,
        isBigEndian: Bool
    ) -> Float {
        let byteCount = raw.count
        guard byteCount > 0 else { return 0.0 }

        var sum: Double = 0.0
        let sampleCount: Int

        if isFloat && bitsPerChannel == 32 {
            sampleCount = byteCount / MemoryLayout<UInt32>.size
            guard sampleCount > 0 else { return 0.0 }
            for i in 0..<sampleCount {
                let rawBits = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                let bits = isBigEndian ? UInt32(bigEndian: rawBits) : UInt32(littleEndian: rawBits)
                let sample = Double(Float(bitPattern: bits))
                if sample.isFinite {
                    sum += sample * sample
                }
            }
        } else if isFloat && bitsPerChannel == 64 {
            sampleCount = byteCount / MemoryLayout<UInt64>.size
            guard sampleCount > 0 else { return 0.0 }
            for i in 0..<sampleCount {
                let rawBits = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
                let bits = isBigEndian ? UInt64(bigEndian: rawBits) : UInt64(littleEndian: rawBits)
                let sample = Double(bitPattern: bits)
                if sample.isFinite {
                    sum += sample * sample
                }
            }
        } else if !isFloat && bitsPerChannel == 32 {
            sampleCount = byteCount / MemoryLayout<Int32>.size
            guard sampleCount > 0 else { return 0.0 }
            let scale = Double(Int32.max)
            for i in 0..<sampleCount {
                let rawValue = raw.loadUnaligned(fromByteOffset: i * 4, as: Int32.self)
                let value = isBigEndian ? Int32(bigEndian: rawValue) : Int32(littleEndian: rawValue)
                let sample = Double(value) / scale
                sum += sample * sample
            }
        } else {
            sampleCount = byteCount / MemoryLayout<Int16>.size
            guard sampleCount > 0 else { return 0.0 }
            let scale = Double(Int16.max)
            for i in 0..<sampleCount {
                let rawValue = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                let value = isBigEndian ? Int16(bigEndian: rawValue) : Int16(littleEndian: rawValue)
                let sample = Double(value) / scale
                sum += sample * sample
            }
        }

        let rms = Float(sqrt(sum / Double(sampleCount)))
        guard rms.isFinite else { return 0.0 }
        return min(1.0, max(0.0, rms * 10.0))
    }
}

// MARK: - Supporting Types

public struct AudioDeviceInfo: Sendable, Identifiable {
    public let id: String
    public let name: String
}
