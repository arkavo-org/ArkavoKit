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

    /// Whether a capture is running. False while one is still opening or stopping, and as soon as it is
    /// stopped or stops by itself.
    public var isActive: Bool {
        state.withLockUnchecked { state in
            if case .running = state { return true }
            return false
        }
    }

    private let sampleHandler = OSAllocatedUnfairLock<((CMSampleBuffer) -> Void)?>(uncheckedState: nil)
    public var onSample: ((CMSampleBuffer) -> Void)? {
        get { sampleHandler.withLockUnchecked { $0 } }
        set { sampleHandler.withLockUnchecked { $0 = newValue } }
    }

    // MARK: - Properties

    private enum StartStep {
        case done
        case open
        case waitForStop
    }

    /// A capture that is opening. Each capture has a token its own stop reports with.
    private struct Opening {
        let token: UUID
        /// Starts made while it opens: they get its outcome (`.done`: they don't open one).
        var joiners: [CheckedContinuation<StartStep, any Error>] = []
        /// A stop came after the last start: the capture is stopped as soon as it opens.
        var stopRequested = false
        /// Stops made while it opens, by id. Each returns once the opening has ended (after the
        /// capture is stopped when it is, at once when a later start kept it or the open failed),
        /// or once its time limit runs out. Whichever takes a stop out of here under the lock
        /// resumes it, so it is resumed once.
        var stopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        /// The capture stopped by itself before it finished opening.
        var stoppedByItself = false
    }

    /// A capture whose `stop()` is in flight. Keeps new starts from opening an overlapping
    /// `SCStream` until the previous capture finishes stopping.
    private struct Stopping {
        var startWaiters: [CheckedContinuation<StartStep, any Error>] = []
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private enum State {
        case idle
        case opening(Opening)
        case running(capture: any ScreenAudioCapture, token: UUID)
        case stopping(Stopping)
    }

    /// How an opening that produced a capture ended.
    private enum OpeningEnd {
        /// The source runs the capture.
        case kept
        /// A stop came after the last start: the capture is stopped, and the starts return.
        case stopped
        /// The capture stopped by itself before it finished opening: the starts throw.
        case stoppedByItself
    }

    /// One state for the source's start, its stop and the capture stopping by itself, which come
    /// from different threads. Holding the opening/stopping state here is what keeps two starts
    /// from opening overlapping captures, and a stop during a start from missing the capture it opens.
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: .idle)
    private let openCapture: OpenScreenAudioCapture

    /// The longest a stop waits for a capture that is still opening. An open can sit behind the
    /// screen recording permission prompt or macOS's screen capture confirmation for as long as
    /// they stay up, and stopping a recording waits for its audio to stop before it finishes the
    /// file. Past this the stop returns; the start still stops the capture once it opens.
    static let openingStopWaitLimit: Duration = .seconds(2)

    /// How long a stop waits for an opening: `openingStopWaitLimit`, shorter in tests.
    private let stopWaitLimit: Duration

    // MARK: - Initialization

    public convenience init(sourceID: String) {
        self.init(sourceID: sourceID, openCapture: SystemAudioCapture.open)
    }

    /// Tests: `openCapture` stands in for ScreenCaptureKit, and `stopWaitLimit` can be short.
    init(
        sourceID: String,
        openCapture: @escaping OpenScreenAudioCapture,
        stopWaitLimit: Duration = ScreenAudioSource.openingStopWaitLimit
    ) {
        self.sourceID = sourceID
        self.openCapture = openCapture
        self.stopWaitLimit = stopWaitLimit
        super.init()
    }

    // MARK: - AudioSource Protocol Methods

    /// Opens a capture. Returns at once while one is running. A start made while one is opening
    /// waits for it and returns or throws as it does, so overlapping starts open one capture.
    /// It also cancels a stop made during that opening: the latest call wins, and that stop returns.
    ///
    /// Throws `RecorderError.screenCaptureUnavailable` when the capture stops by itself before it
    /// finishes opening. A stop made after the last start wins over that: the start returns, as
    /// for any stop during an opening.
    public func start() async throws {
        let token = UUID()
        while true {
            let step = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StartStep, any Error>) in
                let immediate = state.withLockUnchecked { state -> StartStep? in
                    switch state {
                    case .running:
                        return .done
                    case .idle:
                        state = .opening(Opening(token: token))
                        return .open
                    case .opening(var opening):
                        opening.stopRequested = false
                        opening.joiners.append(continuation)
                        state = .opening(opening)
                        return nil
                    case .stopping(var stopping):
                        stopping.startWaiters.append(continuation)
                        state = .stopping(stopping)
                        return nil
                    }
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
            switch step {
            case .done:
                return
            case .waitForStop:
                continue
            case .open:
                break
            }
            break
        }

        let capture: any ScreenAudioCapture
        do {
            capture = try await openCapture(
                { [weak self] sampleBuffer in self?.onSample?(sampleBuffer) },
                { [weak self] _ in self?.captureStoppedByItself(token) }
            )
        } catch {
            let (_, joiners, stops) = finishOpening(token, keeping: nil)
            for joiner in joiners { joiner.resume(throwing: error) }
            for stop in stops { stop.resume() }   // there is no capture to stop
            throw error
        }

        // Kept unless a stop came while it opened, or it has already stopped by itself.
        let (end, joiners, stops) = finishOpening(token, keeping: capture)
        switch end {
        case .kept:
            for joiner in joiners { joiner.resume(returning: .done) }
            for stop in stops { stop.resume() }   // a later start cancelled these stops
            print("🔊 ScreenAudioSource [\(sourceID)] started")
        case .stopped:
            for joiner in joiners { joiner.resume(returning: .done) }
            try? await capture.stop()
            finishStopping()
            for stop in stops { stop.resume() }
            print("🔊 ScreenAudioSource [\(sourceID)] stopped as it started")
        case .stoppedByItself:
            for joiner in joiners { joiner.resume(throwing: RecorderError.screenCaptureUnavailable) }
            try? await capture.stop()
            finishStopping()
            for stop in stops { stop.resume() }
            throw RecorderError.screenCaptureUnavailable
        }
    }

    /// Ends the opening of the capture with `token`: the source runs `capture` unless a stop
    /// came meanwhile or it stopped by itself. When a produced capture must be stopped immediately,
    /// transitions to `.stopping` until `capture.stop()` completes so no overlapping capture opens.
    private func finishOpening(
        _ token: UUID, keeping capture: (any ScreenAudioCapture)?
    ) -> (
        end: OpeningEnd,
        joiners: [CheckedContinuation<StartStep, any Error>],
        stopWaiters: [CheckedContinuation<Void, Never>]
    ) {
        state.withLockUnchecked { state in
            guard case .opening(let opening) = state, opening.token == token else { return (.stopped, [], []) }
            let stops = Array(opening.stopWaiters.values)
            if let capture, !opening.stopRequested, !opening.stoppedByItself {
                state = .running(capture: capture, token: token)
                return (.kept, opening.joiners, stops)
            }
            if capture != nil {
                state = .stopping(Stopping())
            } else {
                state = .idle
            }
            let end: OpeningEnd = opening.stoppedByItself && !opening.stopRequested ? .stoppedByItself : .stopped
            return (end, opening.joiners, stops)
        }
    }

    /// Transitions `.stopping` back to `.idle` and resumes any starts/stops that waited on it.
    private func finishStopping() {
        let (starts, stops) = state.withLockUnchecked { state -> ([CheckedContinuation<StartStep, any Error>], [CheckedContinuation<Void, Never>]) in
            guard case .stopping(let stopping) = state else { return ([], []) }
            state = .idle
            return (stopping.startWaiters, stopping.stopWaiters)
        }
        for waiter in starts { waiter.resume(returning: .waitForStop) }
        for waiter in stops { waiter.resume() }
    }

    /// Transitions the capture to `.stopping` before stopping it: one that already stopped by itself
    /// throws here, and the source always finishes in `.idle` either way so the next start opens a
    /// fresh one without overlapping the outgoing stream.
    ///
    /// A capture still opening is stopped by its start as soon as it opens, and this returns once
    /// it has been, so a caller that awaits this gets no more audio from it. It also returns when
    /// the open fails, and when a start made after it keeps the capture (the latest call wins).
    /// It waits for the opening at most `openingStopWaitLimit`: past that it returns, and the
    /// start still stops the capture once it opens, which may deliver audio until then.
    public func stop() async throws {
        enum StopAction {
            case immediate
            case waitOnOpening
            case waitOnStopping
        }

        let runningBox = OSAllocatedUnfairLock<(any ScreenAudioCapture)?>(uncheckedState: nil)
        let timeoutBox = OSAllocatedUnfairLock<(task: Task<Void, Never>?, cancelled: Bool)>(
            initialState: (nil, false)
        )
        let waiterID = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let action = state.withLockUnchecked { state -> StopAction in
                switch state {
                case .idle:
                    return .immediate
                case .opening(var opening):
                    opening.stopRequested = true
                    opening.stopWaiters[waiterID] = continuation
                    state = .opening(opening)
                    return .waitOnOpening
                case .running(let capture, _):
                    state = .stopping(Stopping())
                    runningBox.withLockUnchecked { $0 = capture }
                    return .immediate
                case .stopping(var stopping):
                    stopping.stopWaiters.append(continuation)
                    state = .stopping(stopping)
                    return .waitOnStopping
                }
            }
            switch action {
            case .immediate:
                continuation.resume()
            case .waitOnStopping:
                break
            case .waitOnOpening:
                let limit = stopWaitLimit
                let task = Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    self?.stopWaitTimedOut(waiterID)
                }
                let alreadyCancelled = timeoutBox.withLock { box -> Bool in
                    if box.cancelled { return true }
                    box.task = task
                    return false
                }
                if alreadyCancelled { task.cancel() }
            }
        }
        // Resumed by the opening's end or by the time limit: cancel the timeout safely under lock.
        let taskToCancel = timeoutBox.withLock { box -> Task<Void, Never>? in
            box.cancelled = true
            let task = box.task
            box.task = nil
            return task
        }
        taskToCancel?.cancel()

        guard let capture = runningBox.withLockUnchecked({ $0 }) else { return }

        do {
            try await capture.stop()
        } catch {
            finishStopping()
            throw error
        }
        finishStopping()

        print("🔊 ScreenAudioSource [\(sourceID)] stopped")
    }

    /// Ends the wait of the stop `waiterID` if it is still waiting on the opening. The opening
    /// keeps `stopRequested`, so its start still stops the capture once it opens.
    private func stopWaitTimedOut(_ waiterID: UUID) {
        let waiter = state.withLockUnchecked { state -> CheckedContinuation<Void, Never>? in
            guard case .opening(var opening) = state,
                  let waiter = opening.stopWaiters.removeValue(forKey: waiterID) else { return nil }
            state = .opening(opening)
            return waiter
        }
        waiter?.resume()
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
