import Foundation

/// Network-safe payload describing remote camera frames or metadata updates.
public struct RemoteCameraMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case videoNALU  // H.264 NAL unit (compressed video)
        case metadata
        case audio
        case handshake
    }

    /// H.264 NAL unit payload for video streaming
    public struct VideoNALUPayload: Codable, Sendable {
        public let sourceID: String
        public let timestamp: TimeInterval
        public let isKeyFrame: Bool  // True for I-frames
        public let naluData: Data    // H.264 NAL unit

        public init(sourceID: String, timestamp: TimeInterval, isKeyFrame: Bool, naluData: Data) {
            self.sourceID = sourceID
            self.timestamp = timestamp
            self.isKeyFrame = isKeyFrame
            self.naluData = naluData
        }
    }

    public struct HandshakePayload: Codable, Sendable {
        public let sourceID: String
        public let deviceName: String

        public init(sourceID: String, deviceName: String) {
            self.sourceID = sourceID
            self.deviceName = deviceName
        }
    }

    public struct AudioPayload: Codable, Sendable {
        public let sourceID: String
        public let timestamp: TimeInterval
        public let sampleRate: Double
        public let channels: Int
        public let audioData: Data

        public init(sourceID: String, timestamp: TimeInterval, sampleRate: Double, channels: Int, audioData: Data) {
            self.sourceID = sourceID
            self.timestamp = timestamp
            self.sampleRate = sampleRate
            self.channels = channels
            self.audioData = audioData
        }
    }

    public let kind: Kind
    public let videoNALU: VideoNALUPayload?
    public let metadata: CameraMetadataEvent?
    public let audio: AudioPayload?
    public let handshake: HandshakePayload?

    public init(kind: Kind, videoNALU: VideoNALUPayload? = nil, metadata: CameraMetadataEvent? = nil, audio: AudioPayload? = nil, handshake: HandshakePayload? = nil) {
        self.kind = kind
        self.videoNALU = videoNALU
        self.metadata = metadata
        self.audio = audio
        self.handshake = handshake
    }

    public static func videoNALU(_ payload: VideoNALUPayload) -> RemoteCameraMessage {
        RemoteCameraMessage(kind: .videoNALU, videoNALU: payload)
    }

    public static func metadata(_ event: CameraMetadataEvent) -> RemoteCameraMessage {
        RemoteCameraMessage(kind: .metadata, metadata: event)
    }

    public static func audio(_ payload: AudioPayload) -> RemoteCameraMessage {
        RemoteCameraMessage(kind: .audio, audio: payload)
    }

    public static func handshake(sourceID: String, deviceName: String) -> RemoteCameraMessage {
        RemoteCameraMessage(kind: .handshake, handshake: HandshakePayload(sourceID: sourceID, deviceName: deviceName))
    }
}
