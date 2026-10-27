import Foundation

/// Why bytes are not an `arkavo.creator-catalog/2` document. An entry's error carries its position in `entries`.
public enum CreatorCatalogError: Error, Sendable, Equatable {
    case tooLarge, malformed, keys, schema, owner, entries, tooManyEntries
    case entryKeys(Int), contentID(Int), duplicateContentID(Int), version(Int), payloadHash(Int), payloadSize(Int)
    case metadataHash(Int), metadataSize(Int)
    /// Two entries name the same metadata TDF.
    case duplicateMetadataHash(Int)
    /// An entry's metadata TDF is also an entry's recording.
    case metadataHashIsPayloadHash(Int)
}

/// Why a fetched catalog is not the one a verified pointer names. `CatalogEnvelope.verify` checks the envelope's bytes
/// (the first three cases); `CreatorCatalog.decode(_:owner:)` checks its decrypted payload (the last two).
public enum CatalogDocumentError: Error, Sendable, Equatable {
    case tooLarge, sizeMismatch, hashMismatch
    case invalid(CreatorCatalogError)
    case ownerMismatch
}

/// A creator's catalog, `arkavo.creator-catalog/2` (tdf-iroh-s3 `docs/creator-catalogs.md`, amended on tdf-iroh-s3#38
/// on 2026-10-27). The document is the payload of one ZTDF, the envelope (`CatalogEnvelope`), whose bytes the signed
/// pointer names. Each entry's title, publish time and attributes are in its own metadata TDF (`CatalogEntryMetadata`),
/// a small ZTDF under the recording's policy. The node never decrypts either, so a publish also sends the entries in the
/// clear as `index` (`encodedIndex()`), which the node checks and never serves.
///
/// - One strict UTF-8 JSON object (`StrictJSON`: no byte-order mark, nothing after it, no repeated key) of at most
///   524,288 bytes, with exactly `schema`, `owner` and `entries`.
/// - At most 1,000 entries, each with exactly `contentID` (unique), `version`, `payloadHash`, `payloadSize`,
///   `metadataHash` and `metadataSize`. Integers are JSON integers: no sign, fraction, exponent or leading zero.
/// - Each `metadataHash` is unique and never any entry's `payloadHash`, so one TDF is never both a recording and
///   metadata.
///
/// Any broken rule refuses the whole document; nothing is repaired or skipped. `encoded()` runs the same checks on what
/// it writes, so it never produces a document the node or a reader refuses.
public struct CreatorCatalog: Sendable, Equatable {
    public static let schema = "arkavo.creator-catalog/2"
    public static let maxDocumentBytes = 524_288
    public static let maxEntries = 1_000
    /// The viewer's limit on a metadata TDF.
    public static let maxMetadataSize = 65_536

    private static let documentKeys: Set<String> = ["schema", "owner", "entries"]
    private static let entryKeys: Set<String> = ["contentID", "version", "payloadHash", "payloadSize", "metadataHash",
                                                 "metadataSize"]

    /// One listed recording.
    public struct Entry: Sendable, Equatable {
        public var contentID: String
        /// 1 to 2^53 − 1. A republish with a different payload uses a larger version.
        public var version: UInt64
        /// BLAKE3 of the recording's TDF bytes, 64 lowercase hex characters.
        public var payloadHash: String
        public var payloadSize: UInt64
        /// BLAKE3 of the metadata TDF's bytes, 64 lowercase hex characters.
        public var metadataHash: String
        public var metadataSize: Int

        public init(contentID: String, version: UInt64, payloadHash: String, payloadSize: UInt64, metadataHash: String,
                    metadataSize: Int) {
            self.contentID = contentID
            self.version = version
            self.payloadHash = payloadHash
            self.payloadSize = payloadSize
            self.metadataHash = metadataHash
            self.metadataSize = metadataSize
        }
    }

    public let owner: String
    /// Ordered by `contentID`. Order carries no meaning in the format.
    public private(set) var entries: [Entry]

    public init(owner: String, entries: [Entry] = []) {
        self.owner = owner
        self.entries = entries.sorted { Self.precedes($0.contentID, $1.contentID) }
    }

    // MARK: - Changes

    public func entry(contentID: String) -> Entry? {
        entries.first { $0.contentID.utf8.elementsEqual(contentID.utf8) }
    }

    /// The version a publish of `payloadHash` as `contentID` takes, which its metadata must carry: 1 for a new
    /// contentID, the listed version when the payload is the same, and one more when it differs. Nil past `maxVersion`.
    public func version(forPublishing contentID: String, payloadHash: String) -> UInt64? {
        guard let listed = entry(contentID: contentID) else { return 1 }
        if listed.payloadHash.utf8.elementsEqual(payloadHash.utf8) { return listed.version }
        return listed.version < CatalogField.maxVersion ? listed.version + 1 : nil
    }

    /// Lists `entry`, replacing any entry with its contentID.
    public mutating func upsert(_ entry: Entry) {
        remove(contentID: entry.contentID)
        let index = entries.firstIndex { Self.precedes(entry.contentID, $0.contentID) } ?? entries.endIndex
        entries.insert(entry, at: index)
    }

    /// Drops a contentID. Returns whether it was listed.
    @discardableResult
    public mutating func remove(contentID: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.contentID.utf8.elementsEqual(contentID.utf8) }) else {
            return false
        }
        entries.remove(at: index)
        return true
    }

    // MARK: - Encoding

    /// The document bytes: sorted keys and unescaped slashes. It throws, rather than produce a document the format
    /// refuses, the error `decode` would give those bytes.
    public func encoded() throws(CreatorCatalogError) -> Data {
        guard entries.count <= Self.maxEntries else { throw .tooManyEntries }
        let document = Document(schema: Self.schema, owner: owner, entries: entries.map(EncodedEntry.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document) else { throw .malformed }
        _ = try Self.decode(data)
        return data
    }

    // MARK: - Decoding

    /// Decodes a document, accepting only one that follows the format.
    public static func decode(_ data: Data) throws(CreatorCatalogError) -> CreatorCatalog {
        guard data.count <= maxDocumentBytes else { throw .tooLarge }
        guard let root = StrictJSON.parse(data)?.object else { throw .malformed }
        guard Set(root.keys) == documentKeys else { throw .keys }
        guard root["schema"] == .string(schema) else { throw .schema }
        guard let owner = root["owner"]?.string, CatalogField.isValidSubject(owner) else { throw .owner }
        guard let items = root["entries"]?.array else { throw .entries }
        return CreatorCatalog(owner: owner, entries: try entries(items))
    }

    /// The entry rules a document and an index share: at most 1,000, each valid, unique contentIDs, then the metadata
    /// hashes.
    private static func entries(_ items: [StrictJSON]) throws(CreatorCatalogError) -> [Entry] {
        guard items.count <= maxEntries else { throw .tooManyEntries }
        var contentIDs = Set<[UInt8]>()
        var entries: [Entry] = []
        entries.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let entry = try self.entry(item, index: index)
            guard contentIDs.insert(Array(entry.contentID.utf8)).inserted else { throw .duplicateContentID(index) }
            entries.append(entry)
        }
        try checkMetadataHashes(entries)
        return entries
    }

    /// Decodes the decrypted payload of an envelope that `CatalogEnvelope.verify` checked against its pointer, and
    /// requires the pointer's owner: the format (`.invalid`), then the owner (`.ownerMismatch`).
    public static func decode(_ payload: Data, owner: String) throws(CatalogDocumentError) -> CreatorCatalog {
        let catalog: CreatorCatalog
        do {
            catalog = try decode(payload)
        } catch {
            throw .invalid(error)
        }
        guard catalog.owner.utf8.elementsEqual(owner.utf8) else { throw .ownerMismatch }
        return catalog
    }

    // MARK: - The index

    /// The entries in the clear, as a publish sends them in `index`: a JSON array of the same entry objects as the
    /// document, in the same order. It throws the error the document's encoding would.
    public func encodedIndex() throws(CreatorCatalogError) -> Data {
        _ = try encoded()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entries.map(EncodedEntry.init)) else { throw .malformed }
        return data
    }

    /// An `index` as the node reads it: a strict JSON array of 0–1,000 entries under the document's entry rules.
    static func decodeIndex(_ data: Data) throws(CreatorCatalogError) -> [Entry] {
        guard data.count <= maxDocumentBytes else { throw .tooLarge }
        guard let items = StrictJSON.parse(data)?.array else { throw .malformed }
        return try entries(items)
    }

    private static func entry(_ value: StrictJSON, index: Int) throws(CreatorCatalogError) -> Entry {
        guard let object = value.object, Set(object.keys) == entryKeys else { throw .entryKeys(index) }
        guard let contentID = object["contentID"]?.string, CatalogField.isValidContentID(contentID) else {
            throw .contentID(index)
        }
        guard let version = CatalogField.integer(object["version"], in: 1...CatalogField.maxVersion) else {
            throw .version(index)
        }
        guard let payloadHash = object["payloadHash"]?.string, CatalogField.isLowercaseHexDigest(payloadHash) else {
            throw .payloadHash(index)
        }
        guard let payloadSize = CatalogField.integer(object["payloadSize"], in: 1...CatalogField.maxPayloadSize) else {
            throw .payloadSize(index)
        }
        guard let metadataHash = object["metadataHash"]?.string, CatalogField.isLowercaseHexDigest(metadataHash) else {
            throw .metadataHash(index)
        }
        guard let metadataSize = CatalogField.integer(object["metadataSize"], in: 1...UInt64(maxMetadataSize)) else {
            throw .metadataSize(index)
        }
        return Entry(contentID: contentID, version: version, payloadHash: payloadHash, payloadSize: payloadSize,
                     metadataHash: metadataHash, metadataSize: Int(metadataSize))
    }

    /// The node's order: for each entry, a repeated `metadataHash` first, then one that is any entry's `payloadHash`.
    private static func checkMetadataHashes(_ entries: [Entry]) throws(CreatorCatalogError) {
        let payloads = Set(entries.map(\.payloadHash))
        var seen = Set<String>()
        for (index, entry) in entries.enumerated() {
            guard seen.insert(entry.metadataHash).inserted else { throw .duplicateMetadataHash(index) }
            guard !payloads.contains(entry.metadataHash) else { throw .metadataHashIsPayloadHash(index) }
        }
    }

    /// contentIDs are ASCII, so byte order is the order the node and every reader see.
    private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    // MARK: - Wire types

    private struct Document: Encodable {
        let schema: String
        let owner: String
        let entries: [EncodedEntry]
    }

    private struct EncodedEntry: Encodable {
        let contentID: String
        let version: UInt64
        let payloadHash: String
        let payloadSize: UInt64
        let metadataHash: String
        let metadataSize: Int

        init(_ entry: Entry) {
            contentID = entry.contentID
            version = entry.version
            payloadHash = entry.payloadHash
            payloadSize = entry.payloadSize
            metadataHash = entry.metadataHash
            metadataSize = entry.metadataSize
        }
    }
}
