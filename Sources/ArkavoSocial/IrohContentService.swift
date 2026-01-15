import CryptoKit
import Foundation
import IrohSwift

// MARK: - ContentTicket

/// Represents an iroh ticket for TDF content
public struct ContentTicket: Sendable, Codable, Hashable {
    /// The iroh blob ticket string (for the descriptor)
    public let ticket: String
    /// Content ID (32-byte SHA256 of assetID)
    public let contentID: Data
    /// Content version at time of publishing
    public let version: Int
    /// Creator's public ID for attribution
    public let creatorPublicID: Data
    /// When the ticket was created
    public let createdAt: Date

    public init(
        ticket: String,
        contentID: Data,
        version: Int,
        creatorPublicID: Data,
        createdAt: Date = Date()
    ) {
        self.ticket = ticket
        self.contentID = contentID
        self.version = version
        self.creatorPublicID = creatorPublicID
        self.createdAt = createdAt
    }
}

// MARK: - TDFManifestLite

/// Lightweight manifest structure for publishing
/// Contains only what's needed for key access, extracted from full TDF manifest
public struct TDFManifestLite: Codable, Sendable, Hashable {
    /// KAS URL for key unwrapping
    public let kasURL: String
    /// RSA-wrapped DEK (base64)
    public let wrappedKey: String
    /// Encryption algorithm (e.g., "AES-128-CBC")
    public let algorithm: String
    /// Initialization vector (base64)
    public let iv: String
    /// Asset identifier (UUID string)
    public let assetID: String
    /// ISO8601 timestamp of protection
    public let protectedAt: String

    public init(
        kasURL: String,
        wrappedKey: String,
        algorithm: String,
        iv: String,
        assetID: String,
        protectedAt: String
    ) {
        self.kasURL = kasURL
        self.wrappedKey = wrappedKey
        self.algorithm = algorithm
        self.iv = iv
        self.assetID = assetID
        self.protectedAt = protectedAt
    }

    /// Parse from raw manifest JSON dictionary
    /// - Parameter json: The manifest.json contents as dictionary
    /// - Returns: Parsed TDFManifestLite
    public static func from(manifestJSON json: [String: Any]) throws -> TDFManifestLite {
        guard let encInfo = json["encryptionInformation"] as? [String: Any],
              let method = encInfo["method"] as? [String: Any],
              let keyAccess = (encInfo["keyAccess"] as? [[String: Any]])?.first,
              let kasURL = keyAccess["url"] as? String,
              let wrappedKey = keyAccess["wrappedKey"] as? String,
              let algorithm = method["algorithm"] as? String,
              let iv = method["iv"] as? String
        else {
            throw IrohContentError.manifestExtractionFailed("Missing required fields in manifest")
        }

        // Try top-level meta first
        var assetID: String?
        var protectedAt: String?

        if let meta = json["meta"] as? [String: Any] {
            assetID = meta["assetId"] as? String
            protectedAt = meta["protectedAt"] as? String
        }

        // Fall back to encryptedMetadata for fMP4 content (base64-encoded JSON)
        if assetID == nil || protectedAt == nil,
           let encryptedMetadata = keyAccess["encryptedMetadata"] as? String,
           let metadataData = Data(base64Encoded: encryptedMetadata),
           let fmp4Meta = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any] {
            assetID = assetID ?? (fmp4Meta["assetId"] as? String)
            protectedAt = protectedAt ?? (fmp4Meta["protectedAt"] as? String)
        }

        guard let finalAssetID = assetID, let finalProtectedAt = protectedAt else {
            throw IrohContentError.manifestExtractionFailed("Missing assetId or protectedAt in manifest")
        }

        return TDFManifestLite(
            kasURL: kasURL,
            wrappedKey: wrappedKey,
            algorithm: algorithm,
            iv: iv,
            assetID: finalAssetID,
            protectedAt: finalProtectedAt
        )
    }
}

// MARK: - TDFContentInfo

/// Platform-agnostic info for TDF content to publish
///
/// Caller (e.g., ArkavoCreator) builds this from a Recording and TDF archive.
public struct TDFContentInfo: Sendable {
    /// Unique content identifier
    public let id: UUID
    /// Full TDF archive data (manifest.json + 0.payload in ZIP)
    public let tdfData: Data
    /// Pre-parsed manifest (caller extracts from TDF)
    public let manifest: TDFManifestLite
    /// Content title
    public let title: String
    /// MIME type (e.g., "video/quicktime")
    public let mimeType: String
    /// Duration in seconds (for video/audio)
    public let durationSeconds: Double?
    /// Original file size before encryption
    public let originalFileSize: Int64
    /// When the content was created
    public let createdAt: Date

    public init(
        id: UUID,
        tdfData: Data,
        manifest: TDFManifestLite,
        title: String,
        mimeType: String,
        durationSeconds: Double?,
        originalFileSize: Int64,
        createdAt: Date
    ) {
        self.id = id
        self.tdfData = tdfData
        self.manifest = manifest
        self.title = title
        self.mimeType = mimeType
        self.durationSeconds = durationSeconds
        self.originalFileSize = originalFileSize
        self.createdAt = createdAt
    }
}

// MARK: - ContentDescriptor

/// Content descriptor published to Iroh
///
/// Contains metadata and a ticket for the full TDF payload.
/// Viewers fetch this first, then use payloadTicket to get the TDF archive.
public struct ContentDescriptor: Codable, Identifiable, Sendable, Hashable {
    /// Unique content identifier
    public let id: UUID
    /// Content ID (32-byte SHA256 of assetID)
    public let contentID: Data
    /// Creator's public ID for attribution
    public let creatorPublicID: Data
    /// Manifest data for KAS access
    public let manifest: TDFManifestLite
    /// Iroh ticket for the full TDF archive
    public let payloadTicket: String
    /// Size of TDF archive in bytes
    public let payloadSize: Int64
    /// Content title
    public var title: String
    /// MIME type
    public var mimeType: String
    /// Duration in seconds
    public var durationSeconds: Double?
    /// Original file size before encryption
    public var originalFileSize: Int64
    /// When the content was created
    public var createdAt: Date
    /// When the descriptor was last updated
    public var updatedAt: Date
    /// Descriptor version
    public var version: Int

    public init(
        id: UUID,
        contentID: Data,
        creatorPublicID: Data,
        manifest: TDFManifestLite,
        payloadTicket: String,
        payloadSize: Int64,
        title: String,
        mimeType: String,
        durationSeconds: Double?,
        originalFileSize: Int64,
        createdAt: Date,
        updatedAt: Date,
        version: Int
    ) {
        self.id = id
        self.contentID = contentID
        self.creatorPublicID = creatorPublicID
        self.manifest = manifest
        self.payloadTicket = payloadTicket
        self.payloadSize = payloadSize
        self.title = title
        self.mimeType = mimeType
        self.durationSeconds = durationSeconds
        self.originalFileSize = originalFileSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
    }
}

// MARK: - IrohContentError

/// Errors specific to content operations
public enum IrohContentError: Error, LocalizedError, Sendable {
    case nodeNotInitialized
    case nativeNodeError(IrohError)
    case ticketInvalid(String)
    case contentNotFound
    case notTDFProtected
    case manifestExtractionFailed(String)
    case encodingError(String)
    case decodingError(String)
    case payloadUploadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nodeNotInitialized:
            "Iroh node is not initialized"
        case let .nativeNodeError(error):
            "Iroh error: \(error.localizedDescription)"
        case let .ticketInvalid(reason):
            "Invalid ticket: \(reason)"
        case .contentNotFound:
            "Content not found"
        case .notTDFProtected:
            "Content is not TDF protected"
        case let .manifestExtractionFailed(msg):
            "Failed to extract TDF manifest: \(msg)"
        case let .encodingError(msg):
            "Failed to encode content: \(msg)"
        case let .decodingError(msg):
            "Failed to decode content: \(msg)"
        case let .payloadUploadFailed(msg):
            "Failed to upload payload: \(msg)"
        }
    }
}

// MARK: - IrohContentService

/// Native iroh service for TDF content publishing and fetching
///
/// Publishes TDF-protected content using a two-part approach:
/// 1. Upload full TDF archive → get payloadTicket
/// 2. Upload ContentDescriptor (with payloadTicket) → get descriptorTicket
///
/// Viewers receive the descriptorTicket, fetch the descriptor,
/// then use payloadTicket to fetch the full TDF archive.
public actor IrohContentService {
    private let node: IrohNode

    /// Create a content service with an initialized iroh node
    /// - Parameter node: An initialized IrohNode
    public init(node: IrohNode) {
        self.node = node
    }

    // MARK: - Publishing

    /// Publish TDF content to the iroh network (two-part: payload + descriptor)
    /// - Parameters:
    ///   - info: Platform-agnostic content info with TDF data
    ///   - creatorPublicID: Creator's public ID for attribution
    /// - Returns: A ContentTicket for sharing and retrieval
    public func publishContent(
        info: TDFContentInfo,
        creatorPublicID: Data
    ) async throws -> ContentTicket {
        // 1. Upload TDF archive data → get payloadTicket
        let payloadTicket: String
        do {
            payloadTicket = try await node.put(info.tdfData)
        } catch let error as IrohError {
            throw IrohContentError.nativeNodeError(error)
        } catch {
            throw IrohContentError.payloadUploadFailed(error.localizedDescription)
        }

        // 2. Generate contentID from assetID
        let contentID = generateContentID(from: info.manifest.assetID)

        // 3. Build ContentDescriptor with payloadTicket
        let descriptor = ContentDescriptor(
            id: info.id,
            contentID: contentID,
            creatorPublicID: creatorPublicID,
            manifest: info.manifest,
            payloadTicket: payloadTicket,
            payloadSize: Int64(info.tdfData.count),
            title: info.title,
            mimeType: info.mimeType,
            durationSeconds: info.durationSeconds,
            originalFileSize: info.originalFileSize,
            createdAt: info.createdAt,
            updatedAt: Date(),
            version: 1
        )

        // 4. Upload descriptor → get descriptorTicket
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let descriptorTicket: String
        do {
            descriptorTicket = try await node.put(descriptor, encoder: encoder)
        } catch let error as IrohError {
            throw IrohContentError.nativeNodeError(error)
        } catch {
            throw IrohContentError.encodingError(error.localizedDescription)
        }

        return ContentTicket(
            ticket: descriptorTicket,
            contentID: contentID,
            version: 1,
            creatorPublicID: creatorPublicID
        )
    }

    /// Publish content with retry on failure
    /// - Parameters:
    ///   - info: Platform-agnostic content info with TDF data
    ///   - creatorPublicID: Creator's public ID for attribution
    ///   - maxAttempts: Maximum retry attempts (default 3)
    /// - Returns: A ContentTicket for sharing and retrieval
    public func publishContentWithRetry(
        info: TDFContentInfo,
        creatorPublicID: Data,
        maxAttempts: Int = 3
    ) async throws -> ContentTicket {
        // 1. Upload TDF archive with retry
        let payloadTicket: String
        do {
            payloadTicket = try await node.putWithRetry(info.tdfData, maxAttempts: maxAttempts)
        } catch let error as IrohError {
            throw IrohContentError.nativeNodeError(error)
        }

        // 2. Generate contentID
        let contentID = generateContentID(from: info.manifest.assetID)

        // 3. Build ContentDescriptor
        let descriptor = ContentDescriptor(
            id: info.id,
            contentID: contentID,
            creatorPublicID: creatorPublicID,
            manifest: info.manifest,
            payloadTicket: payloadTicket,
            payloadSize: Int64(info.tdfData.count),
            title: info.title,
            mimeType: info.mimeType,
            durationSeconds: info.durationSeconds,
            originalFileSize: info.originalFileSize,
            createdAt: info.createdAt,
            updatedAt: Date(),
            version: 1
        )

        // 4. Upload descriptor with retry
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(descriptor)
            let descriptorTicket = try await node.putWithRetry(data, maxAttempts: maxAttempts)
            return ContentTicket(
                ticket: descriptorTicket,
                contentID: contentID,
                version: 1,
                creatorPublicID: creatorPublicID
            )
        } catch let error as IrohError {
            throw IrohContentError.nativeNodeError(error)
        } catch {
            throw IrohContentError.encodingError(error.localizedDescription)
        }
    }

    // MARK: - Fetching

    /// Fetch a content descriptor by ticket
    /// - Parameter ticket: The iroh ticket string (descriptorTicket)
    /// - Returns: The content descriptor
    public func fetchContent(ticket: String) async throws -> ContentDescriptor {
        guard IrohNode.isValidTicket(ticket) else {
            throw IrohContentError.ticketInvalid("Invalid ticket format")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try await node.get(ticket: ticket, as: ContentDescriptor.self, decoder: decoder)
        } catch let error as IrohError {
            throw IrohContentError.nativeNodeError(error)
        }
    }

    /// Fetch a content descriptor by ticket with retry
    /// - Parameters:
    ///   - ticket: The iroh ticket string (descriptorTicket)
    ///   - maxAttempts: Maximum retry attempts (default 3)
    /// - Returns: The content descriptor
    public func fetchContentWithRetry(
        ticket: String,
        maxAttempts: Int = 3
    ) async throws -> ContentDescriptor {
        guard IrohNode.isValidTicket(ticket) else {
            throw IrohContentError.ticketInvalid("Invalid ticket format")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try await node.getWithRetry(ticket: ticket, maxAttempts: maxAttempts)
            return try decoder.decode(ContentDescriptor.self, from: data)
        } catch let error as IrohError {
            throw IrohContentError.nativeNodeError(error)
        } catch {
            throw IrohContentError.decodingError(error.localizedDescription)
        }
    }

    /// Fetch the full TDF archive using the payloadTicket from a descriptor
    /// - Parameter payloadTicket: The iroh ticket for the TDF archive
    /// - Returns: The full TDF archive data
    public func fetchPayload(payloadTicket: String) async throws -> Data {
        guard IrohNode.isValidTicket(payloadTicket) else {
            throw IrohContentError.ticketInvalid("Invalid payload ticket format")
        }

        do {
            return try await node.get(ticket: payloadTicket)
        } catch let error as IrohError {
            throw IrohContentError.nativeNodeError(error)
        }
    }

    /// Fetch the full TDF archive with retry
    /// - Parameters:
    ///   - payloadTicket: The iroh ticket for the TDF archive
    ///   - maxAttempts: Maximum retry attempts (default 3)
    /// - Returns: The full TDF archive data
    public func fetchPayloadWithRetry(
        payloadTicket: String,
        maxAttempts: Int = 3
    ) async throws -> Data {
        guard IrohNode.isValidTicket(payloadTicket) else {
            throw IrohContentError.ticketInvalid("Invalid payload ticket format")
        }

        do {
            return try await node.getWithRetry(ticket: payloadTicket, maxAttempts: maxAttempts)
        } catch let error as IrohError {
            throw IrohContentError.nativeNodeError(error)
        }
    }

    // MARK: - Node Info

    /// Get the current node info
    /// - Returns: Node information including ID and connection status
    public func nodeInfo() async throws -> NodeInfo {
        try await node.info()
    }

    // MARK: - Private Helpers

    /// Generate a 32-byte content ID from the asset ID
    private func generateContentID(from assetID: String) -> Data {
        let data = assetID.data(using: .utf8) ?? Data()
        return Data(SHA256.hash(data: data))
    }
}
