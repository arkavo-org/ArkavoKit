import Foundation

// MARK: - ContentTicketCache

/// Cache for storing content tickets by contentID
///
/// Enables quick P2P lookups by caching the iroh ticket for known content.
/// Persists to UserDefaults for cross-session caching.
public actor ContentTicketCache {
    /// Shared singleton instance
    public static let shared = ContentTicketCache()

    /// In-memory cache: contentID (hex) -> ContentTicket
    private var cache: [String: ContentTicket] = [:]

    /// Maximum number of cached tickets
    private let maxEntries: Int

    /// UserDefaults key for persistence
    private let persistenceKey = "ContentTicketCache"

    private init(maxEntries: Int = 500) {
        self.maxEntries = maxEntries
    }

    // MARK: - Public API

    /// Cache a ticket for content
    /// - Parameters:
    ///   - ticket: The content ticket to cache
    ///   - contentID: The content's ID (32-byte hash)
    public func cache(_ ticket: ContentTicket, for contentID: Data) {
        let key = contentID.hexString
        cache[key] = ticket

        // Evict oldest entries if over limit
        if cache.count > maxEntries {
            evictOldest()
        }
    }

    /// Get cached ticket for a content ID
    /// - Parameter contentID: The content's ID
    /// - Returns: The cached ticket if available
    public func ticket(for contentID: Data) -> ContentTicket? {
        cache[contentID.hexString]
    }

    /// Get cached ticket string for a content ID
    /// - Parameter contentID: The content's ID
    /// - Returns: The cached ticket string if available
    public func ticketString(for contentID: Data) -> String? {
        cache[contentID.hexString]?.ticket
    }

    /// Invalidate cached ticket for a content ID
    /// - Parameter contentID: The content's ID
    public func invalidate(contentID: Data) {
        cache.removeValue(forKey: contentID.hexString)
    }

    /// Clear all cached tickets
    public func clear() {
        cache.removeAll()
    }

    /// Check if a ticket is cached for a content ID
    /// - Parameter contentID: The content's ID
    /// - Returns: True if a ticket is cached
    public func hasCachedTicket(for contentID: Data) -> Bool {
        cache[contentID.hexString] != nil
    }

    /// Get all cached content IDs
    /// - Returns: Array of cached content IDs
    public func cachedContentIDs() -> [Data] {
        cache.keys.compactMap { Data(hexString: $0) }
    }

    /// Number of cached tickets
    public var count: Int {
        cache.count
    }

    /// Get all cached tickets for a creator
    /// - Parameter creatorPublicID: The creator's public ID
    /// - Returns: Array of content tickets from this creator
    public func tickets(for creatorPublicID: Data) -> [ContentTicket] {
        cache.values.filter { $0.creatorPublicID == creatorPublicID }
    }

    // MARK: - Persistence

    /// Save cache to UserDefaults
    public func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    /// Restore cache from UserDefaults
    public func restore() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let restored = try? decoder.decode([String: ContentTicket].self, from: data) {
            cache = restored
        }
    }

    // MARK: - Private

    /// Evict oldest entries to stay under maxEntries
    private func evictOldest() {
        let sorted = cache.sorted { $0.value.createdAt < $1.value.createdAt }
        let toRemove = sorted.prefix(cache.count - maxEntries)
        for (key, _) in toRemove {
            cache.removeValue(forKey: key)
        }
    }
}

// MARK: - Data Extensions

private extension Data {
    /// Convert data to hex string
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Create data from hex string
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex

        for _ in 0 ..< len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index ..< nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}
