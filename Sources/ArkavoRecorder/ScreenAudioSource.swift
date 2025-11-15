import CoreMedia
#if os(macOS)
@preconcurrency import AVFoundation
import ScreenCaptureKit

/// Audio source for capturing system/screen audio on macOS
public final class ScreenAudioSource: NSObject, AudioSource, @unchecked Sendable {
    // MARK: - AudioSource Protocol

    public let sourceID: String
    public var sourceName: String {
        "Screen Audio"
    }

    public var format: AudioFormat {
        // Screen audio output format: 48kHz stereo 16-bit PCM
        AudioFormat(sampleRate: 48000.0, channels: 2, bitDepth: 16, formatID: kAudioFormatLinearPCM)
    }

    nonisolated(unsafe) public private(set) var isActive: Bool = false

    nonisolated(unsafe) public var onSample: ((CMSampleBuffer) -> Void)?

    // MARK: - Properties

    nonisolated(unsafe) private var stream: SCStream?
    nonisolated(unsafe) private var streamOutput: ScreenAudioStreamOutput?
    private let audioQueue = DispatchQueue(label: "com.arkavo.screenaudio")

    // MARK: - Initialization

    public init(sourceID: String) {
        self.sourceID = sourceID
        super.init()
    }

    // MARK: - AudioSource Protocol Methods

    public func start() async throws {
        // Check for screen recording permission on macOS
        guard await checkScreenRecordingPermission() else {
            throw RecorderError.screenCaptureUnavailable
        }

        // Get available content (applications and windows)
        let availableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        // Create filter to capture all audio
        let filter = SCContentFilter(
            display: availableContent.displays.first!,
            excludingApplications: [],
            exceptingWindows: []
        )

        // Configure stream
        let streamConfig = SCStreamConfiguration()
        streamConfig.capturesAudio = true
        streamConfig.sampleRate = 48000 // 48kHz
        streamConfig.channelCount = 2   // Stereo

        // Don't capture video in audio-only source
        streamConfig.width = 1
        streamConfig.height = 1
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // Create stream output handler
        let output = ScreenAudioStreamOutput { [weak self] sampleBuffer in
            self?.onSample?(sampleBuffer)
        }
        self.streamOutput = output

        // Create and start stream
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)

        self.stream = stream
        try await stream.startCapture()

        isActive = true
        print("🔊 ScreenAudioSource [\(sourceID)] started")
    }

    public func stop() async throws {
        guard let stream = stream else { return }

        try await stream.stopCapture()
        self.stream = nil
        self.streamOutput = nil
        isActive = false

        print("🔊 ScreenAudioSource [\(sourceID)] stopped")
    }

    // MARK: - Private Methods

    private func checkScreenRecordingPermission() async -> Bool {
        // ScreenCaptureKit doesn't have a direct permission check API
        // Attempting to get shareable content will trigger permission prompt if needed
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            print("⚠️ ScreenAudioSource: Screen recording permission denied or unavailable: \(error)")
            return false
        }
    }
}

// MARK: - Stream Output Handler

private class ScreenAudioStreamOutput: NSObject, SCStreamOutput {
    private let onAudioSample: (CMSampleBuffer) -> Void

    init(onAudioSample: @escaping (CMSampleBuffer) -> Void) {
        self.onAudioSample = onAudioSample
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Verify this is an audio sample
        guard sampleBuffer.formatDescription?.mediaType == .audio else {
            return
        }

        onAudioSample(sampleBuffer)
    }
}

#else

// Placeholder for non-macOS platforms
public final class ScreenAudioSource: AudioSource {
    public let sourceID: String
    public var sourceName: String { "Screen Audio (unavailable)" }
    public var format: AudioFormat {
        AudioFormat(sampleRate: 48000.0, channels: 2, bitDepth: 16, formatID: kAudioFormatLinearPCM)
    }
    public var isActive: Bool { false }
    public var onSample: ((CMSampleBuffer) -> Void)?

    public init(sourceID: String) {
        self.sourceID = sourceID
    }

    public func start() async throws {
        throw RecorderError.screenCaptureUnavailable
    }

    public func stop() async throws {
        // No-op on non-macOS
    }
}

#endif

