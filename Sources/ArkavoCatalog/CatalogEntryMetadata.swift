import Foundation

/// Why bytes are not a catalog entry's metadata payload.
public enum CatalogEntryMetadataError: Error, Sendable, Equatable {
    case tooLarge, malformed, keys, contentID, version, payloadHash, title, publishedAt, attributeFQNs
}

/// The decrypted payload of a `/2` entry's metadata TDF: exactly `contentID`, `version`, `payloadHash`, `title`,
/// `publishedAt` and `attributeFQNs`, one strict UTF-8 JSON object of at most 65,536 bytes.
///
/// - `title` is required: 1–512 UTF-8 bytes.
/// - `publishedAt` is `YYYY-MM-DDTHH:MM:SSZ`.
/// - `attributeFQNs` holds at most 32 `CatalogField.isAttributeFQN` URLs, for display. They grant nothing.
///
/// The node never decrypts this payload, so these rules live here rather than in the node. The metadata binds to its
/// entry only through the catalog: `isBound(to:)` compares `contentID`, `version` and `payloadHash` with an entry of a
/// verified catalog. Metadata found any other way is not bound to anything, because anyone holding the KAS public key
/// and a recording's attributes can encrypt a payload that names that recording.
public struct CatalogEntryMetadata: Sendable, Equatable {
    /// The metadata TDF's `payload.mimeType`. The node indexes no blob of this type as a recording.
    public static let mimeType = "application/vnd.arkavo.catalog-entry+json"
    public static let maxBytes = CreatorCatalog.maxMetadataSize

    private static let keys: Set<String> = ["contentID", "version", "payloadHash", "title", "publishedAt",
                                            "attributeFQNs"]

    public let contentID: String
    public let version: UInt64
    public let payloadHash: String
    public let title: String
    /// Whole seconds.
    public let publishedAt: Date
    public let attributeFQNs: [String]

    /// `publishedAt` is rounded down to the second. Nothing is checked until `encoded()`.
    public init(contentID: String, version: UInt64, payloadHash: String, title: String, publishedAt: Date,
                attributeFQNs: [String]) {
        self.contentID = contentID
        self.version = version
        self.payloadHash = payloadHash
        self.title = title
        self.publishedAt = Date(timeIntervalSince1970: publishedAt.timeIntervalSince1970.rounded(.down))
        self.attributeFQNs = attributeFQNs
    }

    /// Whether this metadata describes `entry`: the same `contentID`, `version` and `payloadHash`, byte for byte. Call
    /// it only with an entry of a catalog whose pointer verified, after the metadata TDF's bytes hashed to the entry's
    /// `metadataHash`.
    public func isBound(to entry: CreatorCatalog.Entry) -> Bool {
        contentID.utf8.elementsEqual(entry.contentID.utf8) && version == entry.version
            && payloadHash.utf8.elementsEqual(entry.payloadHash.utf8)
    }

    /// The payload bytes, sorted keys and unescaped slashes. It throws, rather than produce a payload the format
    /// refuses, the error `decode` would give those bytes.
    public func encoded() throws(CatalogEntryMetadataError) -> Data {
        guard let stamp = CatalogField.timestamp(publishedAt) else { throw .publishedAt }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = Payload(contentID: contentID, version: version, payloadHash: payloadHash, title: title,
                              publishedAt: stamp, attributeFQNs: attributeFQNs)
        guard let data = try? encoder.encode(payload) else { throw .malformed }
        _ = try Self.decode(data)
        return data
    }

    /// Decodes a payload, accepting only one that follows the format.
    public static func decode(_ data: Data) throws(CatalogEntryMetadataError) -> CatalogEntryMetadata {
        guard data.count <= maxBytes else { throw .tooLarge }
        guard let object = StrictJSON.parse(data)?.object else { throw .malformed }
        guard Set(object.keys) == keys else { throw .keys }
        guard let contentID = object["contentID"]?.string, CatalogField.isValidContentID(contentID) else {
            throw .contentID
        }
        guard let version = CatalogField.integer(object["version"], in: 1...CatalogField.maxVersion) else {
            throw .version
        }
        guard let payloadHash = object["payloadHash"]?.string, CatalogField.isLowercaseHexDigest(payloadHash) else {
            throw .payloadHash
        }
        guard let title = object["title"]?.string, CatalogField.isValidTitle(title) else { throw .title }
        guard let stamp = object["publishedAt"]?.string, let publishedAt = CatalogField.timestamp(stamp) else {
            throw .publishedAt
        }
        guard let items = object["attributeFQNs"]?.array, items.count <= CatalogField.maxAttributeFQNs else {
            throw .attributeFQNs
        }
        var attributeFQNs: [String] = []
        for item in items {
            guard let text = item.string, CatalogField.isAttributeFQN(text) else { throw .attributeFQNs }
            attributeFQNs.append(text)
        }
        return CatalogEntryMetadata(contentID: contentID, version: version, payloadHash: payloadHash, title: title,
                                    publishedAt: publishedAt, attributeFQNs: attributeFQNs)
    }

    private struct Payload: Encodable {
        let contentID: String
        let version: UInt64
        let payloadHash: String
        let title: String
        let publishedAt: String
        let attributeFQNs: [String]
    }
}
