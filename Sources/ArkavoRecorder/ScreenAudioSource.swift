import CoreMedia
#if os(macOS)
@preconcurrency import AVFoundation
import os
import ScreenCaptureKit

/// One running capture of the system audio.
protocol ScreenAudioCapture: AnyObject {
    func stop() async throws
}

/// Opens a capture of the system audio. `onSample` receives its audio; `onStop` is called if the
/// capture stops by itself (sharing ended, displays changed, the capture service restarted).
typealias OpenScreenAudioCapture = (
    _ onSample: @escaping (CMSampleBuffer) -> Void,
    _ onStop: @escaping (any Error) -> Void
) async throws -> any ScreenAudioCapture

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

    /// Whether a capture is running. False as soon as it is stopped, or stops by itself.
    public var isActive: Bool { running.withLockUnchecked { $0 != nil } }

    nonisolated(unsafe) public var onSample: ((CMSampleBuffer) -> Void)?

    // MARK: - Properties

    /// The running capture and the token its own stop reports with. A capture's start, its stop
    /// and its stopping by itself come from different threads.
    private let running = OSAllocatedUnfairLock<(capture: any ScreenAudioCapture, token: UUID)?>(uncheckedState: nil)
    private let openCapture: OpenScreenAudioCapture

    // MARK: - Initialization

    public convenience init(sourceID: String) {
        self.init(sourceID: sourceID, openCapture: SystemAudioCapture.open)
    }

    /// Tests: `openCapture` stands in for ScreenCaptureKit.
    init(sourceID: String, openCapture: @escaping OpenScreenAudioCapture) {
        self.sourceID = sourceID
        self.openCapture = openCapture
        super.init()
    }

    // MARK: - AudioSource Protocol Methods

    public func start() async throws {
        let token = UUID()
        let capture = try await openCapture(
            { [weak self] sampleBuffer in self?.onSample?(sampleBuffer) },
            { [weak self] _ in self?.captureStoppedByItself(token) }
        )
        running.withLockUnchecked { $0 = (capture, token) }
        print("🔊 ScreenAudioSource [\(sourceID)] started")
    }

    /// Forgets the capture before stopping it: one that already stopped by itself throws here,
    /// and the source must read as stopped either way, so the next start opens a fresh one.
    public func stop() async throws {
        let capture = running.withLockUnchecked { running -> (any ScreenAudioCapture)? in
            defer { running = nil }
            return running?.capture
        }
        guard let capture else { return }

        try await capture.stop()

        print("🔊 ScreenAudioSource [\(sourceID)] stopped")
    }

    /// A capture that stopped by itself is over. A late report from one this source has since
    /// replaced doesn't touch the newer one.
    private func captureStoppedByItself(_ token: UUID) {
        running.withLockUnchecked { running in
            if running?.token == token { running = nil }
        }
    }

    // MARK: - Private Methods

    /// 48 kHz stereo system audio, excluding this app's own output: audio the host app mixes
    /// directly (Creator's Muse voice) would otherwise reach the mix a second time, delayed.
    static func makeStreamConfiguration() -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.sampleRate = 48000 // 48kHz
        streamConfig.channelCount = 2   // Stereo

        // Don't capture video in audio-only source
        // Smallest video surface WindowServer reliably creates (1x1 can fail IOSurface creation).
        streamConfig.width = 2
        streamConfig.height = 2
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return streamConfig
    }
}

// MARK: - System Audio Capture

/// The system audio, captured by an SCStream.
private final class SystemAudioCapture: ScreenAudioCapture {
    private let stream: SCStream
    /// The stream keeps neither its output nor its delegate.
    private let output: ScreenAudioStreamOutput
    private let delegate: ScreenAudioStreamDelegate

    private init(stream: SCStream, output: ScreenAudioStreamOutput, delegate: ScreenAudioStreamDelegate) {
        self.stream = stream
        self.output = output
        self.delegate = delegate
    }

    static func open(
        _ onSample: @escaping (CMSampleBuffer) -> Void,
        _ onStop: @escaping (any Error) -> Void
    ) async throws -> any ScreenAudioCapture {
        // Check for screen recording permission on macOS
        guard await hasScreenRecordingPermission() else {
            throw RecorderError.screenCaptureUnavailable
        }

        // Get available content (applications and windows)
        let availableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        // Create filter to capture all audio. The display only anchors the stream (system audio
        // is not per-display), so use the main display: `displays.first` can be a display
        // WindowServer cannot open a stream on (seen with a portrait secondary panel), and then
        // the whole capture fails with CoreGraphicsErrorDomain 1003.
        guard let display = availableContent.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? availableContent.displays.first
        else {
            throw RecorderError.screenCaptureUnavailable
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let output = ScreenAudioStreamOutput(onAudioSample: onSample)
        let delegate = ScreenAudioStreamDelegate(onStop: onStop)
        let stream = SCStream(filter: filter, configuration: ScreenAudioSource.makeStreamConfiguration(), delegate: delegate)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.arkavo.screenaudio"))
        try await stream.startCapture()
        return SystemAudioCapture(stream: stream, output: output, delegate: delegate)
    }

    func stop() async throws {
        try await stream.stopCapture()
    }

    private static func hasScreenRecordingPermission() async -> Bool {
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

/// Reports a stream that stopped by itself.
private final class ScreenAudioStreamDelegate: NSObject, SCStreamDelegate {
    private let onStop: (any Error) -> Void

    init(onStop: @escaping (any Error) -> Void) {
        self.onStop = onStop
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop(error)
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

