import CryptoKit
import Foundation

// MARK: - CreatorProfile

/// Full creator profile with extended fields for ArkavoCreator/Arkavo apps
/// Synced via iroh network to iroh.arkavo.net
public struct CreatorProfile: Codable, Identifiable, Sendable, Hashable {
    // MARK: - Identity

    public let id: UUID
    /// 32-byte SHA256 hash, matches Profile.publicID format
    public let publicID: Data
    public var did: String?
    public var handle: String?

    // MARK: - Display Information

    public var displayName: String
    public var bio: String
    public var avatarURL: URL?
    public var bannerURL: URL?

    // MARK: - Social Links

    public var socialLinks: [CreatorSocialLink]

    // MARK: - Content

    public var contentCategories: [ContentCategory]
    public var streamingSchedule: StreamingSchedule?
    public var patronTiers: [PatronTier]
    /// publicIDs of featured content
    public var featuredContentIDs: [Data]

    // MARK: - Metadata

    public var createdAt: Date
    public var updatedAt: Date
    /// Version for sync conflict resolution
    public var version: Int

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        publicID: Data? = nil,
        did: String? = nil,
        handle: String? = nil,
        displayName: String = "",
        bio: String = ""
    ) {
        self.id = id
        self.publicID = publicID ?? Self.generatePublicID(from: id)
        self.did = did
        self.handle = handle
        self.displayName = displayName
        self.bio = bio
        avatarURL = nil
        bannerURL = nil
        socialLinks = []
        contentCategories = []
        streamingSchedule = nil
        patronTiers = []
        featuredContentIDs = []
        createdAt = Date()
        updatedAt = Date()
        version = 1
    }

    // MARK: - Public ID Generation

    /// Generate publicID from UUID (matches Profile.swift pattern)
    public static func generatePublicID(from id: UUID) -> Data {
        withUnsafeBytes(of: id) { buffer in
            Data(SHA256.hash(data: buffer))
        }
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: CreatorProfile, rhs: CreatorProfile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Serialization

public extension CreatorProfile {
    /// Serialize to Data for network transmission
    func toData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Deserialize from Data
    static func fromData(_ data: Data) throws -> CreatorProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CreatorProfile.self, from: data)
    }
}

// MARK: - CreatorSocialLink

public struct CreatorSocialLink: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var platform: CreatorSocialPlatform
    public var username: String
    public var url: URL
    public var isVerified: Bool

    public init(
        id: UUID = UUID(),
        platform: CreatorSocialPlatform,
        username: String,
        url: URL,
        isVerified: Bool = false
    ) {
        self.id = id
        self.platform = platform
        self.username = username
        self.url = url
        self.isVerified = isVerified
    }
}

// MARK: - CreatorSocialPlatform

public enum CreatorSocialPlatform: String, Codable, CaseIterable, Sendable {
    case twitter = "Twitter"
    case instagram = "Instagram"
    case youtube = "YouTube"
    case tiktok = "TikTok"
    case twitch = "Twitch"
    case bluesky = "Bluesky"
    case patreon = "Patreon"
    case discord = "Discord"
    case reddit = "Reddit"
    case custom = "Custom"

    public var iconName: String {
        switch self {
        case .twitter: "bird"
        case .instagram: "camera"
        case .youtube: "play.rectangle.fill"
        case .tiktok: "music.note"
        case .twitch: "tv"
        case .bluesky: "cloud"
        case .patreon: "heart.circle"
        case .discord: "bubble.left.and.bubble.right"
        case .reddit: "globe"
        case .custom: "link"
        }
    }

    public var baseURL: String? {
        switch self {
        case .twitter: "https://twitter.com/"
        case .instagram: "https://instagram.com/"
        case .youtube: "https://youtube.com/@"
        case .tiktok: "https://tiktok.com/@"
        case .twitch: "https://twitch.tv/"
        case .bluesky: "https://bsky.app/profile/"
        case .patreon: "https://patreon.com/"
        case .discord: nil
        case .reddit: "https://reddit.com/user/"
        case .custom: nil
        }
    }
}

// MARK: - ContentCategory

public enum ContentCategory: String, Codable, CaseIterable, Sendable {
    case gaming = "Gaming"
    case music = "Music"
    case art = "Art"
    case technology = "Technology"
    case education = "Education"
    case lifestyle = "Lifestyle"
    case entertainment = "Entertainment"
    case sports = "Sports"
    case news = "News"
    case cooking = "Cooking"
    case fitness = "Fitness"
    case travel = "Travel"
    case science = "Science"
    case comedy = "Comedy"
    case other = "Other"

    public var iconName: String {
        switch self {
        case .gaming: "gamecontroller"
        case .music: "music.note.list"
        case .art: "paintbrush"
        case .technology: "laptopcomputer"
        case .education: "book"
        case .lifestyle: "heart"
        case .entertainment: "star"
        case .sports: "sportscourt"
        case .news: "newspaper"
        case .cooking: "fork.knife"
        case .fitness: "figure.run"
        case .travel: "airplane"
        case .science: "atom"
        case .comedy: "face.smiling"
        case .other: "ellipsis.circle"
        }
    }
}

// MARK: - StreamingSchedule

public struct StreamingSchedule: Codable, Sendable, Hashable {
    public var slots: [ScheduleSlot]
    public var timezone: String

    public init(
        slots: [ScheduleSlot] = [],
        timezone: String = TimeZone.current.identifier
    ) {
        self.slots = slots
        self.timezone = timezone
    }
}

// MARK: - ScheduleSlot

public struct ScheduleSlot: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    /// Day of week: 1 = Sunday, 7 = Saturday
    public var dayOfWeek: Int
    /// Start time as hours and minutes
    public var startHour: Int
    public var startMinute: Int
    /// Duration in minutes
    public var durationMinutes: Int
    public var title: String?

    public init(
        id: UUID = UUID(),
        dayOfWeek: Int,
        startHour: Int,
        startMinute: Int = 0,
        durationMinutes: Int = 60,
        title: String? = nil
    ) {
        self.id = id
        self.dayOfWeek = dayOfWeek
        self.startHour = startHour
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.title = title
    }

    public var dayName: String {
        switch dayOfWeek {
        case 1: "Sunday"
        case 2: "Monday"
        case 3: "Tuesday"
        case 4: "Wednesday"
        case 5: "Thursday"
        case 6: "Friday"
        case 7: "Saturday"
        default: "Unknown"
        }
    }

    public var formattedTime: String {
        let hour = startHour % 12 == 0 ? 12 : startHour % 12
        let period = startHour < 12 ? "AM" : "PM"
        if startMinute == 0 {
            return "\(hour) \(period)"
        } else {
            return String(format: "%d:%02d %@", hour, startMinute, period)
        }
    }
}

// MARK: - PatronTier

public struct PatronTier: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var description: String
    /// Price in cents (e.g., 500 = $5.00)
    public var priceCents: Int
    public var benefits: [String]
    public var isActive: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        priceCents: Int,
        benefits: [String] = [],
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.priceCents = priceCents
        self.benefits = benefits
        self.isActive = isActive
    }

    public var formattedPrice: String {
        let dollars = Double(priceCents) / 100.0
        return String(format: "$%.2f/mo", dollars)
    }
}
