import Foundation

// MARK: - ProfileTicketCache

/// Cache for storing profile tickets by publicID
///
/// Enables quick P2P lookups by caching the iroh ticket for known profiles.
/// Persists to UserDefaults for cross-session caching.
public actor ProfileTicketCache {
    /// Shared singleton instance
    public static let shared = ProfileTicketCache()

    /// In-memory cache: publicID (hex) -> ProfileTicket
    private var cache: [String: ProfileTicket] = [:]

    /// Maximum number of cached tickets
    private let maxEntries: Int

    /// UserDefaults key for persistence
    private let persistenceKey = "ProfileTicketCache"

    private init(maxEntries: Int = 100) {
        self.maxEntries = maxEntries
    }

    // MARK: - Public API

    /// Cache a ticket for a profile
    /// - Parameters:
    ///   - ticket: The profile ticket to cache
    ///   - publicID: The profile's public ID
    public func cache(_ ticket: ProfileTicket, for publicID: Data) {
        let key = publicID.hexString
        cache[key] = ticket

        // Evict oldest entries if over limit
        if cache.count > maxEntries {
            evictOldest()
        }
    }

    /// Get cached ticket for a public ID
    /// - Parameter publicID: The profile's public ID
    /// - Returns: The cached ticket if available
    public func ticket(for publicID: Data) -> ProfileTicket? {
        cache[publicID.hexString]
    }

    /// Get cached ticket string for a public ID
    /// - Parameter publicID: The profile's public ID
    /// - Returns: The cached ticket string if available
    public func ticketString(for publicID: Data) -> String? {
        cache[publicID.hexString]?.ticket
    }

    /// Invalidate cached ticket for a public ID
    /// - Parameter publicID: The profile's public ID
    public func invalidate(publicID: Data) {
        cache.removeValue(forKey: publicID.hexString)
    }

    /// Clear all cached tickets
    public func clear() {
        cache.removeAll()
    }

    /// Check if a ticket is cached for a public ID
    /// - Parameter publicID: The profile's public ID
    /// - Returns: True if a ticket is cached
    public func hasCachedTicket(for publicID: Data) -> Bool {
        cache[publicID.hexString] != nil
    }

    /// Get all cached public IDs
    /// - Returns: Array of cached public IDs
    public func cachedPublicIDs() -> [Data] {
        cache.keys.compactMap { Data(hexString: $0) }
    }

    /// Number of cached tickets
    public var count: Int {
        cache.count
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

        if let restored = try? decoder.decode([String: ProfileTicket].self, from: data) {
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
