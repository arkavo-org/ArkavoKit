import Foundation

/// BMFF container formats accepted by the arkavo-rs signing server
public enum C2PAContainerFormat: String, Codable, Sendable {
    case mov
    case mp4

    /// Maps a file extension to the server's container format. M4A and M4V are
    /// MP4 files; the server has no separate value for them.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "mov": self = .mov
        case "mp4", "m4a", "m4v": self = .mp4
        default: return nil
        }
    }
}

/// Provenance details the server writes into the manifest
public struct C2PASigningMetadata: Encodable, Sendable {
    public let title: String
    public let creator: String
    public let description: String?
    /// Becomes the `when` of the manifest's `c2pa.created` action. Sent with
    /// whole seconds so the manifest size does not vary between requests.
    public let timestamp: Date
    public let aiGenerated: Bool?
    public let software: String?

    public init(
        title: String,
        creator: String,
        description: String? = nil,
        timestamp: Date = Date(),
        aiGenerated: Bool? = nil,
        software: String? = nil
    ) {
        self.title = title
        self.creator = creator
        self.description = description
        self.timestamp = timestamp
        self.aiGenerated = aiGenerated
        self.software = software
    }

    enum CodingKeys: String, CodingKey {
        case title
        case creator
        case description
        case timestamp
        case aiGenerated = "ai_generated"
        case software
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(creator, forKey: .creator)
        try container.encodeIfPresent(description, forKey: .description)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        try container.encode(formatter.string(from: timestamp), forKey: .timestamp)
        try container.encodeIfPresent(aiGenerated, forKey: .aiGenerated)
        try container.encodeIfPresent(software, forKey: .software)
    }
}

/// Byte range left out of the content hash; `end` is exclusive
public struct C2PAExclusionRange: Encodable, Equatable, Sendable {
    public let start: UInt64
    public let end: UInt64
    public let boxType: String?

    public init(start: UInt64, end: UInt64, boxType: String? = nil) {
        self.start = start
        self.end = end
        self.boxType = boxType
    }

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case boxType = "box_type"
    }
}

/// Body of `POST /c2pa/v1/sign`
public struct C2PASignRequest: Encodable, Sendable {
    /// Hex SHA-256 of the asset with `exclusionRanges` left out
    public let contentHash: String
    public let exclusionRanges: [C2PAExclusionRange]
    public let containerFormat: C2PAContainerFormat
    public let metadata: C2PASigningMetadata

    public init(
        contentHash: String,
        exclusionRanges: [C2PAExclusionRange],
        containerFormat: C2PAContainerFormat,
        metadata: C2PASigningMetadata
    ) {
        self.contentHash = contentHash
        self.exclusionRanges = exclusionRanges
        self.containerFormat = containerFormat
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case exclusionRanges = "exclusion_ranges"
        case containerFormat = "container_format"
        case metadata
    }
}

/// Client for the arkavo-rs C2PA signing endpoint. The server signs a manifest
/// over a hash the client computed, so the asset itself is never uploaded.
public struct C2PASigningService: Sendable {
    public static let defaultServerURL = URL(string: "https://platform.arkavo.net")!

    /// Returns the identity.arkavo.net passkey token (the one `ArkavoClient.currentToken`
    /// holds), or nil to send the request without one
    public typealias AccessTokenProvider = @Sendable () async throws -> String?

    public enum ServiceError: Error, LocalizedError {
        /// The bearer token was missing or the server rejected it
        case unauthenticated(String)
        /// The server's creator allowlist does not include `metadata.creator`
        case creatorNotAuthorized(String)
        /// The exclusion range was not the size of the signed manifest box. The server
        /// discarded the manifest; ask again with a range of `requiredLength` bytes.
        case exclusionLengthMismatch(requiredLength: Int)
        /// Too many sign requests for this account; `retryAfter` is in seconds
        case rateLimited(retryAfter: TimeInterval?)
        case server(statusCode: Int, message: String)
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .unauthenticated(let message):
                return "C2PA signing needs an Arkavo sign-in: \(message)"
            case .creatorNotAuthorized(let message):
                return "C2PA signing denied: \(message)"
            case .exclusionLengthMismatch(let requiredLength):
                return "C2PA signing needs a \(requiredLength)-byte manifest range"
            case .rateLimited(let retryAfter):
                return "Too many C2PA sign requests"
                    + (retryAfter.map { "; retry in \(Int($0)) s" } ?? "")
            case .server(let statusCode, let message):
                return "C2PA signing server error (HTTP \(statusCode)): \(message)"
            case .invalidResponse(let message):
                return "Invalid C2PA signing response: \(message)"
            }
        }
    }

    public let serverURL: URL
    private let session: URLSession
    private let accessToken: AccessTokenProvider?

    public init(
        serverURL: URL = Self.defaultServerURL,
        session: URLSession = .shared,
        accessToken: AccessTokenProvider? = nil
    ) {
        self.serverURL = serverURL
        self.session = session
        self.accessToken = accessToken
    }

    /// Returns the signed manifest store (JUMBF) for the client to embed
    public func signManifest(_ signRequest: C2PASignRequest) async throws -> Data {
        var request = URLRequest(url: serverURL.appendingPathComponent("c2pa/v1/sign"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(signRequest)
        if let token = try await accessToken?() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse("not an HTTP response")
        }
        let body = try? JSONDecoder().decode(SignResponse.self, from: data)

        switch http.statusCode {
        case 200:
            guard let manifest = body?.manifest else {
                throw ServiceError.invalidResponse("missing manifest")
            }
            guard let jumbf = Data(base64Encoded: manifest) else {
                throw ServiceError.invalidResponse("manifest is not base64")
            }
            return jumbf
        case 401:
            throw ServiceError.unauthenticated(body?.message ?? body?.error ?? "authentication required")
        case 403:
            throw ServiceError.creatorNotAuthorized(body?.error ?? "creator not authorized")
        case 422 where body?.requiredExclusionLength != nil:
            throw ServiceError.exclusionLengthMismatch(requiredLength: body?.requiredExclusionLength ?? 0)
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ServiceError.rateLimited(retryAfter: retryAfter)
        default:
            let message = body?.error ?? String(decoding: data, as: UTF8.self)
            throw ServiceError.server(statusCode: http.statusCode, message: message)
        }
    }

    private struct SignResponse: Decodable {
        let manifest: String?
        let error: String?
        let message: String?
        let requiredExclusionLength: Int?

        enum CodingKeys: String, CodingKey {
            case manifest
            case error
            case message
            case requiredExclusionLength = "required_exclusion_length"
        }
    }
}
