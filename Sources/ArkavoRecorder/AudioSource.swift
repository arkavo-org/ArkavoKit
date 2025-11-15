import AVFoundation
import CoreMedia

/// Represents the audio format characteristics of an audio source
public struct AudioFormat {
    public let sampleRate: Double
    public let channels: UInt32
    public let bitDepth: UInt32
    public let formatID: AudioFormatID

    public init(sampleRate: Double, channels: UInt32, bitDepth: UInt32, formatID: AudioFormatID) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.formatID = formatID
    }

    /// Create AudioFormat from CMFormatDescription
    public init?(from formatDescription: CMFormatDescription) {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return nil
        }

        self.sampleRate = asbd.mSampleRate
        self.channels = asbd.mChannelsPerFrame
        self.bitDepth = asbd.mBitsPerChannel
        self.formatID = asbd.mFormatID
    }

    /// Create AudioFormat from AudioStreamBasicDescription
    public init(from asbd: AudioStreamBasicDescription) {
        self.sampleRate = asbd.mSampleRate
        self.channels = asbd.mChannelsPerFrame
        self.bitDepth = asbd.mBitsPerChannel
        self.formatID = asbd.mFormatID
    }
}

/// Protocol for any audio source that can provide audio samples
public protocol AudioSource: AnyObject {
    /// Unique identifier for this audio source
    var sourceID: String { get }

    /// Human-readable name for the source (e.g., "Microphone", "Screen Audio", "Remote Camera - iPhone")
    var sourceName: String { get }

    /// The current audio format this source produces
    var format: AudioFormat { get }

    /// Whether this source is currently active and producing samples
    var isActive: Bool { get }

    /// Callback when a new audio sample is available
    var onSample: ((CMSampleBuffer) -> Void)? { get set }

    /// Start capturing audio from this source
    func start() async throws

    /// Stop capturing audio from this source
    func stop() async throws
}

/// Extension providing helper functionality
public extension AudioSource {
    /// Format description string for debugging
    var formatDescription: String {
        "\(format.sampleRate)Hz, \(format.channels)ch, \(format.bitDepth)-bit, formatID: \(format.formatID)"
    }
}
