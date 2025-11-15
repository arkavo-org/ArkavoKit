import AVFoundation
import CoreMedia

/// Coordinates multiple audio sources, applies format conversion, and routes to encoder
public class AudioRouter {
    // MARK: - Properties

    private var sources: [String: AudioSource] = [:]
    private var converters: [String: AudioFormatConverter] = [:]

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

    /// Add an audio source to the router
    /// - Parameter source: Audio source to add
    public func addSource(_ source: AudioSource) {
        let sourceID = source.sourceID

        // Create format converter for this source
        let converter = AudioFormatConverter(
            targetSampleRate: targetSampleRate,
            targetChannels: targetChannels,
            sourceID: sourceID
        )

        sources[sourceID] = source
        converters[sourceID] = converter

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
        converters.removeValue(forKey: sourceID)

        print("🎛️ AudioRouter: Removed source [\(sourceID)]")
    }

    /// Start all audio sources
    public func startAll() async throws {
        print("🎛️ AudioRouter: Starting all sources...")

        for (sourceID, source) in sources {
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
        // Log first sample from each source
        if sampleCount[sourceID] == nil {
            print("🎵 AudioRouter: First sample received from [\(sourceID)]")
            sampleCount[sourceID] = 0
        }
        sampleCount[sourceID]! += 1

        // Log every 100 samples
        if sampleCount[sourceID]! % 100 == 0 {
            print("🎵 AudioRouter: Received \(sampleCount[sourceID]!) samples from [\(sourceID)]")
        }

        guard let converter = converters[sourceID] else {
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
