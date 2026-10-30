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

    /// Whether a capture is running. False while one is still opening, and as soon as it is
    /// stopped or stops by itself.
    public var isActive: Bool {
        state.withLockUnchecked { state in
            if case .running = state { return true }
            return false
        }
    }

    nonisolated(unsafe) public var onSample: ((CMSampleBuffer) -> Void)?

    // MARK: - Properties

    /// A capture that is opening. Each capture has a token its own stop reports with.
    private struct Opening {
        let token: UUID
        /// Starts made while it opens: they get its outcome (`false`: they don't open one).
        var joiners: [CheckedContinuation<Bool, any Error>] = []
        /// A stop came after the last start: the capture is stopped as soon as it opens.
        var stopRequested = false
        /// The capture stopped by itself before it finished opening.
        var stoppedByItself = false
    }

    private enum State {
        case idle
        case opening(Opening)
        case running(capture: any ScreenAudioCapture, token: UUID)
    }

    /// One state for the source's start, its stop and the capture stopping by itself, which come
    /// from different threads. Holding the opening state here is what keeps two starts from
    /// opening two captures, and a stop during a start from missing the capture it opens.
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: .idle)
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

    /// Opens a capture. Returns at once while one is running. A start made while one is opening
    /// waits for it and returns or throws as it does, so overlapping starts open one capture.
    /// It also cancels a stop made during that opening: the latest call wins.
    public func start() async throws {
        let token = UUID()
        let opens = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            let joined = state.withLockUnchecked { state -> Bool? in
                switch state {
                case .running:
                    return false
                case .idle:
                    state = .opening(Opening(token: token))
                    return true
                case .opening(var opening):
                    opening.stopRequested = false
                    opening.joiners.append(continuation)
                    state = .opening(opening)
                    return nil
                }
            }
            if let joined { continuation.resume(returning: joined) }
        }
        guard opens else { return }

        let capture: any ScreenAudioCapture
        do {
            capture = try await openCapture(
                { [weak self] sampleBuffer in self?.onSample?(sampleBuffer) },
                { [weak self] _ in self?.captureStoppedByItself(token) }
            )
        } catch {
            for joiner in finishOpening(token, keeping: nil).joiners { joiner.resume(throwing: error) }
            throw error
        }

        // Kept unless a stop came while it opened, or it has already stopped by itself.
        let (kept, joiners) = finishOpening(token, keeping: capture)
        for joiner in joiners { joiner.resume(returning: false) }
        if kept {
            print("🔊 ScreenAudioSource [\(sourceID)] started")
        } else {
            try? await capture.stop()
            print("🔊 ScreenAudioSource [\(sourceID)] stopped as it started")
        }
    }

    /// Ends the opening of the capture with `token`: the source runs `capture` unless a stop
    /// came meanwhile or it stopped by itself, and is idle otherwise. Returns whether it was
    /// kept, and the starts that joined the opening.
    private func finishOpening(
        _ token: UUID, keeping capture: (any ScreenAudioCapture)?
    ) -> (kept: Bool, joiners: [CheckedContinuation<Bool, any Error>]) {
        state.withLockUnchecked { state in
            guard case .opening(let opening) = state, opening.token == token else { return (false, []) }
            if let capture, !opening.stopRequested, !opening.stoppedByItself {
                state = .running(capture: capture, token: token)
                return (true, opening.joiners)
            }
            state = .idle
            return (false, opening.joiners)
        }
    }

    /// Forgets the capture before stopping it: one that already stopped by itself throws here,
    /// and the source must read as stopped either way, so the next start opens a fresh one.
    /// A capture still opening is stopped by its start as soon as it opens; this returns at once.
    public func stop() async throws {
        let capture = state.withLockUnchecked { state -> (any ScreenAudioCapture)? in
            switch state {
            case .idle:
                return nil
            case .opening(var opening):
                opening.stopRequested = true
                state = .opening(opening)
                return nil
            case .running(let capture, _):
                state = .idle
                return capture
            }
        }
        guard let capture else { return }

        try await capture.stop()

        print("🔊 ScreenAudioSource [\(sourceID)] stopped")
    }

    /// A capture that stopped by itself is over, including one still opening. A late report from
    /// one this source has since replaced doesn't touch the newer one.
    private func captureStoppedByItself(_ token: UUID) {
        state.withLockUnchecked { state in
            switch state {
            case .running(_, let running) where running == token:
                state = .idle
            case .opening(var opening) where opening.token == token:
                opening.stoppedByItself = true
                state = .opening(opening)
            default:
                break
            }
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

