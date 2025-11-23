import Foundation
import CoreMedia

/// Represents an encoded audio frame ready for streaming or storage
public struct EncodedAudioFrame: Sendable {
    /// AAC-encoded audio data
    public let data: Data

    /// Presentation timestamp
    public let pts: CMTime

    /// Audio format information (sample rate, channels)
    public let formatDescription: CMAudioFormatDescription?

    public init(data: Data, pts: CMTime, formatDescription: CMAudioFormatDescription? = nil) {
        self.data = data
        self.pts = pts
        self.formatDescription = formatDescription
    }
}

/// Represents an encoded video frame ready for streaming or storage
public struct EncodedVideoFrame: Sendable {
    /// H.264-encoded video data
    public let data: Data

    /// Presentation timestamp
    public let pts: CMTime

    /// Whether this is a keyframe (I-frame)
    public let isKeyframe: Bool

    /// Video format information (dimensions, codec parameters)
    public let formatDescription: CMVideoFormatDescription?

    public init(data: Data, pts: CMTime, isKeyframe: Bool, formatDescription: CMVideoFormatDescription? = nil) {
        self.data = data
        self.pts = pts
        self.isKeyframe = isKeyframe
        self.formatDescription = formatDescription
    }
}
