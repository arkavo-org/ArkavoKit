import Foundation

/// Product identifiers for StoreKit 2 integration
public enum ProductIdentifier {
    // MARK: - Subscription Products (Encryption Tiers)

    public static let encryptionMediumMonthly = "com.arkavo.encryption.medium.monthly"
    public static let encryptionMediumYearly = "com.arkavo.encryption.medium.yearly"
    public static let encryptionHighMonthly = "com.arkavo.encryption.high.monthly"
    public static let encryptionHighYearly = "com.arkavo.encryption.high.yearly"

    // MARK: - All Products

    public static let allSubscriptions: Set<String> = [
        encryptionMediumMonthly,
        encryptionMediumYearly,
        encryptionHighMonthly,
        encryptionHighYearly,
    ]

    public static let allProducts: Set<String> = allSubscriptions

    // MARK: - Subscription Group

    public static let subscriptionGroupID = "arkavo_encryption"
}

/// Encryption levels available across the product line
public enum EncryptionLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    /// Display name for UI
    public var displayName: String {
        rawValue
    }

    /// Technical description
    public var technicalDescription: String {
        switch self {
        case .low:
            "Standard AES-256 encryption"
        case .medium:
            "Enhanced encryption with additional key derivation"
        case .high:
            "Maximum security with hardware-backed keys and forward secrecy"
        }
    }

    /// User-friendly description
    public var description: String {
        switch self {
        case .low:
            "Basic protection for general content"
        case .medium:
            "Enhanced protection for sensitive content"
        case .high:
            "Maximum protection for confidential content"
        }
    }

    public static func < (lhs: EncryptionLevel, rhs: EncryptionLevel) -> Bool {
        let order: [EncryptionLevel] = [.low, .medium, .high]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs)
        else {
            return false
        }
        return lhsIndex < rhsIndex
    }
}

/// Entitlement tiers that determine encryption level
public enum EntitlementTier: String, Codable, CaseIterable, Sendable {
    case low = "Basic"
    case medium = "Enhanced"
    case high = "Maximum"

    /// Encryption level for this tier
    public var encryptionLevel: EncryptionLevel {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    /// Display name for UI
    public var displayName: String {
        rawValue
    }

    /// Description for UI
    public var description: String {
        encryptionLevel.description
    }

    /// Technical description
    public var technicalDescription: String {
        encryptionLevel.technicalDescription
    }

    /// Whether this is a paid tier
    public var isPaid: Bool {
        self != .low
    }
}

/// Maps product identifiers to entitlement tiers
public enum ProductTierMapping {
    public static func tier(for productID: String) -> EntitlementTier {
        switch productID {
        case ProductIdentifier.encryptionMediumMonthly,
             ProductIdentifier.encryptionMediumYearly:
            .medium
        case ProductIdentifier.encryptionHighMonthly,
             ProductIdentifier.encryptionHighYearly:
            .high
        default:
            .low
        }
    }

    public static func productIDs(for tier: EntitlementTier) -> [String] {
        switch tier {
        case .low:
            []
        case .medium:
            [ProductIdentifier.encryptionMediumMonthly, ProductIdentifier.encryptionMediumYearly]
        case .high:
            [ProductIdentifier.encryptionHighMonthly, ProductIdentifier.encryptionHighYearly]
        }
    }
}

/// Stream limit constant
public enum StreamConfiguration {
    public static let streamLimit = 100
}
