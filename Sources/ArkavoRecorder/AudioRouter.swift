import AVFoundation
import CoreMedia

/// Coordinates multiple audio sources, applies format conversion, and routes to encoder
public class AudioRouter {
    // MARK: - Properties

    private var sources: [String: AudioSource] = [:]
    private var converters: [String: AudioFormatConverter] = [:]
    /// Guards `converters` and `sampleCount`: each source delivers on its own capture queue
    private let lock = NSLock()

    /// Target output format (48kHz stereo PCM for AAC encoding)
    private let targetSampleRate: Double = 48000.0
    private let targetChannels: UInt32 = 2

    /// Callback when converted audio sample is ready for encoding
    public var onConvertedSample: ((CMSampleBuffer, String) -> Void)?

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
        if let replaced = sources[sourceID], replaced !== source {
            replaced.onSample = nil
            let stopping = ReplacedSource(source: replaced)
            Task { @MainActor in try? await stopping.source.stop() }
        }

        // Create format converter for this source
        let converter = AudioFormatConverter(
            targetSampleRate: targetSampleRate,
            targetChannels: targetChannels,
            sourceID: sourceID
        )

        sources[sourceID] = source
        lock.lock(); converters[sourceID] = converter; lock.unlock()

        // Set up callback to receive samples from this source
        source.onSample = { [weak self] sampleBuffer in
            self?.processSample(sampleBuffer, from: sourceID)
        }

        print("🎛️ AudioRouter: Added source [\(sourceID)] - \(source.sourceName)")
    }

    /// Remove an audio source from the router
    /// - Parameter sourceID: Source identifier to remove
    public func removeSource(_ sourceID: String) {
        sources[sourceID]?.onSample = nil
        sources.removeValue(forKey: sourceID)
        lock.lock(); converters.removeValue(forKey: sourceID); lock.unlock()

        print("🎛️ AudioRouter: Removed source [\(sourceID)]")
    }

    /// Stops an audio source, then removes it
    func stopAndRemoveSource(_ sourceID: String) async {
        try? await sources[sourceID]?.stop()
        removeSource(sourceID)
    }

    /// Start all audio sources that aren't running. Starting a running source again could open a
    /// second capture of it.
    public func startAll() async throws {
        print("🎛️ AudioRouter: Starting all sources...")

        for (sourceID, source) in sources where !source.isActive {
            do {
                try await source.start()
                print("  ✓ Started [\(sourceID)]")
            } catch {
                print("  ✗ Failed to start [\(sourceID)]: \(error)")
                throw error
            }
        }

        print("🎛️ AudioRouter: All sources started")
    }

    /// Stop all audio sources
    public func stopAll() async throws {
        print("🎛️ AudioRouter: Stopping all sources...")

        for (sourceID, source) in sources {
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
        sources.filter { $0.value.isActive }.map { $0.key }
    }

    /// Get all source IDs
    public var allSourceIDs: [String] {
        Array(sources.keys)
    }

    // MARK: - Private Methods

    private var sampleCount: [String: Int] = [:]

    private func processSample(_ sampleBuffer: CMSampleBuffer, from sourceID: String) {
        lock.lock()
        let isFirstSample = sampleCount[sourceID] == nil
        sampleCount[sourceID, default: 0] += 1
        let converter = converters[sourceID]
        lock.unlock()

        // Log first sample from each source
        if isFirstSample {
            print("🎵 AudioRouter: First sample received from [\(sourceID)]")
        }

        guard let converter else {
            print("⚠️ AudioRouter: No converter for source [\(sourceID)]")
            return
        }

        // Convert sample to target format
        guard let convertedSample = converter.convert(sampleBuffer) else {
            print("⚠️ AudioRouter: Failed to convert sample from source [\(sourceID)]")
            return
        }

        // Forward converted sample to encoder callback
        onConvertedSample?(convertedSample, sourceID)
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
