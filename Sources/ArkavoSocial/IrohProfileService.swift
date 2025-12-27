import Foundation
import IrohSwift

// MARK: - ProfileTicket

/// Represents an iroh ticket for profile data
public struct ProfileTicket: Sendable, Codable, Hashable {
    /// The iroh blob ticket string
    public let ticket: String
    /// The profile's public ID (32 bytes)
    public let publicID: Data
    /// Profile version at time of publishing
    public let version: Int
    /// When the ticket was created
    public let createdAt: Date

    public init(ticket: String, publicID: Data, version: Int, createdAt: Date = Date()) {
        self.ticket = ticket
        self.publicID = publicID
        self.version = version
        self.createdAt = createdAt
    }
}

// MARK: - IrohProfileError

/// Errors specific to profile operations
public enum IrohProfileError: Error, LocalizedError, Sendable {
    case nodeNotInitialized
    case nativeNodeError(IrohError)
    case ticketInvalid(String)
    case profileNotFound
    case encodingError(String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .nodeNotInitialized:
            "Iroh node is not initialized"
        case let .nativeNodeError(error):
            "Iroh error: \(error.localizedDescription)"
        case let .ticketInvalid(reason):
            "Invalid ticket: \(reason)"
        case .profileNotFound:
            "Profile not found"
        case let .encodingError(msg):
            "Failed to encode profile: \(msg)"
        case let .decodingError(msg):
            "Failed to decode profile: \(msg)"
        }
    }
}

// MARK: - IrohProfileService

/// Native iroh service for profile synchronization
///
/// Provides direct peer-to-peer profile publishing and fetching via iroh-swift.
/// No HTTP fallback - all operations are P2P.
public actor IrohProfileService {
    private let node: IrohNode

    /// Create a profile service with an initialized iroh node
    /// - Parameter node: An initialized IrohNode
    public init(node: IrohNode) {
        self.node = node
    }

    // MARK: - Publishing

    /// Publish a creator profile to the iroh network
    /// - Parameter profile: The creator profile to publish
    /// - Returns: A ProfileTicket for sharing and retrieval
    public func publishProfile(_ profile: CreatorProfile) async throws -> ProfileTicket {
        // Use ISO8601 date encoding for consistency
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let ticket = try await node.put(profile, encoder: encoder)
            return ProfileTicket(
                ticket: ticket,
                publicID: profile.publicID,
                version: profile.version,
                createdAt: Date()
            )
        } catch let error as IrohError {
            throw IrohProfileError.nativeNodeError(error)
        }
    }

    /// Update a creator profile (creates new version)
    /// - Parameter profile: The updated creator profile
    /// - Returns: A new ProfileTicket for the updated profile
    public func updateProfile(_ profile: CreatorProfile) async throws -> ProfileTicket {
        var updatedProfile = profile
        updatedProfile.updatedAt = Date()
        updatedProfile.version += 1
        return try await publishProfile(updatedProfile)
    }

    /// Publish profile with retry on failure
    /// - Parameters:
    ///   - profile: The creator profile to publish
    ///   - maxAttempts: Maximum retry attempts (default 3)
    /// - Returns: A ProfileTicket for sharing and retrieval
    public func publishProfileWithRetry(
        _ profile: CreatorProfile,
        maxAttempts: Int = 3
    ) async throws -> ProfileTicket {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(profile)
            let ticket = try await node.putWithRetry(data, maxAttempts: maxAttempts)
            return ProfileTicket(
                ticket: ticket,
                publicID: profile.publicID,
                version: profile.version,
                createdAt: Date()
            )
        } catch let error as IrohError {
            throw IrohProfileError.nativeNodeError(error)
        } catch {
            throw IrohProfileError.encodingError(error.localizedDescription)
        }
    }

    // MARK: - Fetching

    /// Fetch a creator profile by ticket
    /// - Parameter ticket: The iroh ticket string
    /// - Returns: The creator profile
    public func fetchProfile(ticket: String) async throws -> CreatorProfile {
        // Validate ticket format
        guard IrohNode.isValidTicket(ticket) else {
            throw IrohProfileError.ticketInvalid("Invalid ticket format")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try await node.get(ticket: ticket, as: CreatorProfile.self, decoder: decoder)
        } catch let error as IrohError {
            throw IrohProfileError.nativeNodeError(error)
        }
    }

    /// Fetch a creator profile by ticket with retry
    /// - Parameters:
    ///   - ticket: The iroh ticket string
    ///   - maxAttempts: Maximum retry attempts (default 3)
    /// - Returns: The creator profile
    public func fetchProfileWithRetry(
        ticket: String,
        maxAttempts: Int = 3
    ) async throws -> CreatorProfile {
        guard IrohNode.isValidTicket(ticket) else {
            throw IrohProfileError.ticketInvalid("Invalid ticket format")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try await node.getWithRetry(ticket: ticket, maxAttempts: maxAttempts)
            return try decoder.decode(CreatorProfile.self, from: data)
        } catch let error as IrohError {
            throw IrohProfileError.nativeNodeError(error)
        } catch {
            throw IrohProfileError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Sync

    /// Sync a profile - publish and return new ticket
    /// - Parameter profile: The profile to sync
    /// - Returns: The new ProfileTicket
    public func syncProfile(_ profile: CreatorProfile) async throws -> ProfileTicket {
        try await updateProfile(profile)
    }

    // MARK: - Node Info

    /// Get the current node info
    /// - Returns: Node information including ID and connection status
    public func nodeInfo() async throws -> NodeInfo {
        try await node.info()
    }
}
