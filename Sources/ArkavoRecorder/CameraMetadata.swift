import Foundation

/// Generic metadata payloads describing additional context for a camera feed.
public enum CameraMetadata: Sendable, Codable {
    case arFace(ARFaceMetadata)
    case arBody(ARBodyMetadata)
    case custom(name: String, payload: [String: Float])

    private enum CodingKeys: String, CodingKey {
        case type
        case face
        case body
        case name
        case payload
    }

    private enum MetadataType: String, Codable {
        case arFace
        case arBody
        case custom
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .arFace(face):
            try container.encode(MetadataType.arFace, forKey: .type)
            try container.encode(face, forKey: .face)
        case let .arBody(body):
            try container.encode(MetadataType.arBody, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .custom(name, payload):
            try container.encode(MetadataType.custom, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(payload, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MetadataType.self, forKey: .type)

        switch type {
        case .arFace:
            let face = try container.decode(ARFaceMetadata.self, forKey: .face)
            self = .arFace(face)
        case .arBody:
            let body = try container.decode(ARBodyMetadata.self, forKey: .body)
            self = .arBody(body)
        case .custom:
            let name = try container.decode(String.self, forKey: .name)
            let payload = try container.decode([String: Float].self, forKey: .payload)
            self = .custom(name: name, payload: payload)
        }
    }
}

/// Simplified representation of ARKit face tracking data.
public struct ARFaceMetadata: Sendable, Codable {
    public let blendShapes: [String: Float]
    public let trackingState: ARFaceTrackingState

    public init(blendShapes: [String: Float], trackingState: ARFaceTrackingState = .unknown) {
        self.blendShapes = blendShapes
        self.trackingState = trackingState
    }
}

/// Simplified representation of ARKit body tracking data.
public struct ARBodyMetadata: Sendable, Codable {
    public struct Joint: Sendable, Codable {
        public let name: String
        public let transform: [Float]

        public init(name: String, transform: [Float]) {
            self.name = name
            self.transform = transform
        }
    }

    public let joints: [Joint]

    public init(joints: [Joint]) {
        self.joints = joints
    }
}

/// High-level tracking status for AR face feeds.
public enum ARFaceTrackingState: String, Sendable, Codable {
    case normal
    case limited
    case notTracking
    case unknown
}

/// Metadata event describing which camera produced the payload.
public struct CameraMetadataEvent: Sendable, Codable {
    public let sourceID: String
    public let metadata: CameraMetadata
    public let timestamp: Date

    public init(sourceID: String, metadata: CameraMetadata, timestamp: Date = Date()) {
        self.sourceID = sourceID
        self.metadata = metadata
        self.timestamp = timestamp
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case sourceID
        case metadata
        case timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        metadata = try container.decode(CameraMetadata.self, forKey: .metadata)

        // Decode timestamp as Double (timeIntervalSinceReferenceDate)
        let timestampValue = try container.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSinceReferenceDate: timestampValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(metadata, forKey: .metadata)

        // Encode timestamp as Double (timeIntervalSinceReferenceDate)
        try container.encode(timestamp.timeIntervalSinceReferenceDate, forKey: .timestamp)
    }
}
