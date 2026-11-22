import AVFoundation
import CoreMedia

/// Coordinates multiple audio sources, applies format conversion, and routes to encoder
public class AudioRouter: @unchecked Sendable {
    // MARK: - Properties

    private var sources: [String: AudioSource] = [:]
    private var converters: [String: LockedConverter] = [:]
    /// Guards `sources`, `converters`, `sampleCount`, and `_onConvertedSample`:
    /// each source delivers on its own capture queue.
    private let lock = NSLock()

    /// Target output format (48kHz stereo PCM for AAC encoding)
    private let targetSampleRate: Double = 48000.0
    private let targetChannels: UInt32 = 2

    private var _onConvertedSample: ((CMSampleBuffer, String) -> Void)?
    /// Callback when converted audio sample is ready for encoding
    public var onConvertedSample: ((CMSampleBuffer, String) -> Void)? {
        get { lock.withLock { _onConvertedSample } }
        set { lock.withLock { _onConvertedSample = newValue } }
    }

    // MARK: - Initialization

    public init() {
        print("🎛️ AudioRouter initialized (target: \(targetSampleRate)Hz, \(targetChannels)ch)")
    }

    // MARK: - Public Methods

    /// Add an audio source to the router. A source already added with the same ID is replaced:
    /// it is detached and stopped, since nothing could stop it once the router lets it go.
    /// - Parameter source: Audio source to add
    public func addSource(_ source: AudioSource) {
        let sourceID = source.sourceID
        let sourceToken = ObjectIdentifier(source)

        // Create format converter for this source
        let converter = LockedConverter(AudioFormatConverter(
            targetSampleRate: targetSampleRate,
            targetChannels: targetChannels,
            sourceID: sourceID
        ))

        let replaced: (any AudioSource)? = lock.withLock {
            let previous = sources[sourceID]
            sources[sourceID] = source
            converters[sourceID] = converter
            if let previous, previous !== source {
                return previous
            }
            return nil
        }

        if let replaced {
            replaced.onSample = nil
            let stopping = ReplacedSource(source: replaced)
            Task { @MainActor in try? await stopping.source.stop() }
        }

        // Set up callback to receive samples from this source
        source.onSample = { [weak self] sampleBuffer in
            self?.processSample(sampleBuffer, from: sourceID, sourceToken: sourceToken)
        }

        print("🎛️ AudioRouter: Added source [\(sourceID)] - \(source.sourceName)")
    }

    /// Remove an audio source from the router
    /// - Parameter sourceID: Source identifier to remove
    public func removeSource(_ sourceID: String) {
        let removed: (any AudioSource)? = lock.withLock {
            let source = sources.removeValue(forKey: sourceID)
            converters.removeValue(forKey: sourceID)
            return source
        }
        removed?.onSample = nil

        print("🎛️ AudioRouter: Removed source [\(sourceID)]")
    }

    /// Stops an audio source, then removes it only if it has not been replaced in the meantime.
    func stopAndRemoveSource(_ sourceID: String) async {
        let target: (source: any AudioSource, token: ObjectIdentifier)? = lock.withLock {
            guard let source = sources[sourceID] else { return nil }
            return (source, ObjectIdentifier(source))
        }
        guard let target else { return }

        target.source.onSample = nil
        try? await target.source.stop()

        let removed: Bool = lock.withLock {
            guard let current = sources[sourceID], ObjectIdentifier(current) == target.token else {
                return false
            }
            sources.removeValue(forKey: sourceID)
            converters.removeValue(forKey: sourceID)
            return true
        }
        if removed {
            print("🎛️ AudioRouter: Removed source [\(sourceID)]")
        }
    }

    /// Starts one source unless it is already running.
    func startSource(_ sourceID: String) async throws {
        guard let source = lock.withLock({ sources[sourceID] }), !source.isActive else { return }
        try await source.start()
    }

    /// Stops one source, leaving it registered.
    func stopSource(_ sourceID: String) async throws {
        guard let source = lock.withLock({ sources[sourceID] }) else { return }
        try await source.stop()
    }

    /// Start all audio sources that aren't running. Starting a running source again could open a
    /// second capture of it. A source that fails to start doesn't keep the others from starting:
    /// each is tried, and the first error is thrown once all have been.
    public func startAll() async throws {
        print("🎛️ AudioRouter: Starting all sources...")

        let snapshot = lock.withLock { Array(sources) }
        var firstError: (any Error)?
        for (sourceID, source) in snapshot where !source.isActive {
            do {
                try await source.start()
                print("  ✓ Started [\(sourceID)]")
            } catch {
                print("  ✗ Failed to start [\(sourceID)]: \(error)")
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }

        print("🎛️ AudioRouter: All sources started")
    }

    /// Stop all audio sources
    public func stopAll() async throws {
        print("🎛️ AudioRouter: Stopping all sources...")

        let snapshot = lock.withLock { Array(sources) }
        for (sourceID, source) in snapshot {
            do {
                try await source.stop()
                print("  ✓ Stopped [\(sourceID)]")
            } catch {
                print("  ✗ Failed to stop [\(sourceID)]: \(error)")
            }
        }

        print("🎛️ AudioRouter: All sources stopped")
    }

    /// Get list of active source IDs
    public var activeSourceIDs: [String] {
        let snapshot = lock.withLock { Array(sources) }
        return snapshot.filter { $0.value.isActive }.map { $0.key }
    }

    /// Get all source IDs
    public var allSourceIDs: [String] {
        lock.withLock { Array(sources.keys) }
    }

    // MARK: - Private Methods

    private var sampleCount: [String: Int] = [:]

    private func processSample(_ sampleBuffer: CMSampleBuffer, from sourceID: String, sourceToken: ObjectIdentifier) {
        let (isFirstSample, converter): (Bool, LockedConverter?) = lock.withLock {
            // Drop late samples from a source that has already been removed or replaced.
            guard let current = sources[sourceID], ObjectIdentifier(current) == sourceToken else {
                return (false, nil)
            }
            let first = sampleCount[sourceID] == nil
            sampleCount[sourceID, default: 0] += 1
            return (first, converters[sourceID])
        }

        guard let converter else {
            return
        }

        // Log first sample from each source
        if isFirstSample {
            print("🎵 AudioRouter: First sample received from [\(sourceID)]")
        }

        // Convert sample to target format (serialized per source)
        guard let convertedSample = converter.convert(sampleBuffer) else {
            print("⚠️ AudioRouter: Failed to convert sample from source [\(sourceID)]")
            return
        }

        // Forward converted sample to encoder callback
        let callback = lock.withLock { _onConvertedSample }
        callback?(convertedSample, sourceID)
    }
}

/// Serializes calls to a single source's non-thread-safe `AVAudioConverter`.
private final class LockedConverter: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AudioFormatConverter

    init(_ converter: AudioFormatConverter) {
        self.converter = converter
    }

    func convert(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return converter.convert(sampleBuffer)
    }
}

/// A source the router no longer holds, handed to the task that stops it.
private struct ReplacedSource: @unchecked Sendable {
    let source: any AudioSource
}

// MARK: - Convenience Methods

public extension AudioRouter {
    /// Create and add a microphone audio source
    @MainActor
    func addMicrophone(deviceID: String? = nil) -> MicrophoneAudioSource {
        let source = MicrophoneAudioSource(sourceID: "microphone", deviceID: deviceID)
        addSource(source)
        return source
    }

    /// Create and add a screen audio source (macOS only)
    @MainActor
    func addScreenAudio() -> ScreenAudioSource {
        let source = ScreenAudioSource(sourceID: "screen")
        addSource(source)
        return source
    }

    /// Create and add a remote camera audio source
    func addRemoteCameraAudio(sourceID: String, sourceName: String) -> RemoteCameraAudioSource {
        let source = RemoteCameraAudioSource(sourceID: sourceID, sourceName: sourceName)
        addSource(source)
        return source
    }
}
