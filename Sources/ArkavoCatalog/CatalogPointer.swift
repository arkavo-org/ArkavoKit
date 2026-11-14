import Foundation

/// A creator's catalog pointer: the small document their passkey signs, naming their current catalog document (the
/// envelope) by BLAKE3 hash and size and, from `/2` on, its clear index by SHA-256 (tdf-iroh-s3 `docs/creator-catalogs.md`,
/// "The pointer").
///
/// One strict JSON object of 1 to 1,024 bytes, in one of two schemas:
/// - `arkavo.catalog-pointer/2` (`schema`): exactly `schema`, `owner`, `seq`, `catalogHash`, `catalogSize`, `indexHash` and
///   `issuedAt`. `indexHash` is the catalog's `CreatorCatalog.canonicalIndexHash()`, so the passkey covers the index the
///   node checks. Once the node switches to `/2`, it accepts only `/2` in a publish; until then it refuses `/2`.
/// - `arkavo.catalog-pointer/1` (`schema1`): exactly the other six keys. After the switch the node still serves a stored
///   `/1` until the creator's next publish replaces it, so readers decode both.
///
/// A `/2` without `indexHash`, a `/1` with one (even `null`), and any other schema are refused. `bytes` are the bytes the
/// passkey signed. They are carried base64url-encoded and never re-serialized: `decode` keeps the bytes exactly as received,
/// and the builder writes them once. `issuedAt` is checked for its format only and is never compared with the clock.
public struct CatalogPointer: Sendable, Equatable {
    /// The schema a publish carries once the node switches: seven keys, `indexHash` among them.
    public static let schema = "arkavo.catalog-pointer/2"
    /// The schema before `indexHash`: exactly six keys. Still read; after its switch the node refuses it in a publish.
    public static let schema1 = "arkavo.catalog-pointer/1"
    public static let maxBytes = 1_024
    public static let maxSeq: UInt64 = 9_007_199_254_740_991
    private static let keys1: Set<String> = ["schema", "owner", "seq", "catalogHash", "catalogSize", "issuedAt"]
    private static let keys: Set<String> = keys1.union(["indexHash"])

    /// The signed bytes.
    public let bytes: Data
    public let owner: String
    public let seq: UInt64
    /// BLAKE3 of the catalog document, 64 lowercase hex characters.
    public let catalogHash: String
    /// The catalog document's length, 1 to `CreatorCatalog.maxDocumentBytes`.
    public let catalogSize: Int
    /// A `/2` pointer's SHA-256 of the catalog's canonical index (`CreatorCatalog.canonicalIndexHash()`), 64 lowercase hex
    /// characters. Nil for a `/1`, which signs no index.
    public let indexHash: String?
    /// Whole seconds.
    public let issuedAt: Date

    /// The `/2` pointer to sign, over the catalog's `canonicalIndexHash()`. It writes the seven keys in the contract's order
    /// (`indexHash` between `catalogSize` and `issuedAt`) with no whitespace, integers in decimal and `issuedAt` as
    /// `YYYY-MM-DDTHH:MM:SSZ`, rounded down to the second. Throws `CatalogBundleError.pointer` when a value breaks the
    /// format, so the bytes never need JSON escaping.
    public init(owner: String, seq: UInt64, catalogHash: String, catalogSize: Int, indexHash: String,
                issuedAt: Date) throws(CatalogBundleError) {
        self = try Self.build(owner: owner, seq: seq, catalogHash: catalogHash, catalogSize: catalogSize,
                              indexHash: indexHash, issuedAt: issuedAt)
    }

    /// The `/1` pointer: the same conventions, six keys, no `indexHash`.
    @available(*, deprecated, message: "The node accepts only arkavo.catalog-pointer/2 publishes. Use init(owner:seq:catalogHash:catalogSize:indexHash:issuedAt:) with the catalog's canonicalIndexHash().")
    public init(owner: String, seq: UInt64, catalogHash: String, catalogSize: Int,
                issuedAt: Date) throws(CatalogBundleError) {
        self = try Self.build(owner: owner, seq: seq, catalogHash: catalogHash, catalogSize: catalogSize, indexHash: nil,
                              issuedAt: issuedAt)
    }

    /// `/2` with an `indexHash`, `/1` without.
    private static func build(owner: String, seq: UInt64, catalogHash: String, catalogSize: Int, indexHash: String?,
                              issuedAt: Date) throws(CatalogBundleError) -> CatalogPointer {
        guard CatalogField.isValidSubject(owner), (1...maxSeq).contains(seq),
              CatalogField.isLowercaseHexDigest(catalogHash), (1...CreatorCatalog.maxDocumentBytes).contains(catalogSize),
              indexHash.map(CatalogField.isLowercaseHexDigest) ?? true,
              let stamp = CatalogField.timestamp(issuedAt) else { throw .pointer }
        let (name, indexHashMember) = indexHash.map { (schema, #""indexHash":"\#($0)","#) } ?? (schema1, "")
        let bytes = Data(#"{"schema":"\#(name)","owner":"\#(owner)","seq":\#(seq),"catalogHash":"\#(catalogHash)","catalogSize":\#(catalogSize),\#(indexHashMember)"issuedAt":"\#(stamp)"}"#.utf8)
        guard bytes.count <= maxBytes else { throw .pointer }
        return CatalogPointer(bytes: bytes, owner: owner, seq: seq, catalogHash: catalogHash, catalogSize: catalogSize,
                              indexHash: indexHash,
                              issuedAt: Date(timeIntervalSince1970: issuedAt.timeIntervalSince1970.rounded(.down)))
    }

    private init(bytes: Data, owner: String, seq: UInt64, catalogHash: String, catalogSize: Int, indexHash: String?,
                 issuedAt: Date) {
        self.bytes = bytes
        self.owner = owner
        self.seq = seq
        self.catalogHash = catalogHash
        self.catalogSize = catalogSize
        self.indexHash = indexHash
        self.issuedAt = issuedAt
    }

    /// Throws `CatalogBundleError.pointer` for anything that is not a valid `/2` or `/1` pointer, as the node's
    /// `parse_pointer` reads them. Surrounding whitespace is allowed. The caller compares `owner` with the subject it asked
    /// for.
    public static func decode(_ bytes: Data) throws(CatalogBundleError) -> CatalogPointer {
        guard (1...maxBytes).contains(bytes.count), let root = StrictJSON.parse(bytes)?.object,
              let name = root["schema"]?.string else { throw .pointer }
        let indexHash: String?
        if name.utf8.elementsEqual(schema.utf8) {
            guard Set(root.keys) == keys, let hash = root["indexHash"]?.string, CatalogField.isLowercaseHexDigest(hash) else {
                throw .pointer
            }
            indexHash = hash
        } else if name.utf8.elementsEqual(schema1.utf8), Set(root.keys) == keys1 {
            indexHash = nil
        } else {
            throw .pointer
        }
        guard let owner = root["owner"]?.string, CatalogField.isValidSubject(owner),
              let seq = CatalogField.integer(root["seq"], in: 1...maxSeq),
              let catalogHash = root["catalogHash"]?.string, CatalogField.isLowercaseHexDigest(catalogHash),
              let size = CatalogField.integer(root["catalogSize"], in: 1...UInt64(CreatorCatalog.maxDocumentBytes)),
              let stamp = root["issuedAt"]?.string, let issuedAt = CatalogField.timestamp(stamp) else {
            throw .pointer
        }
        return CatalogPointer(bytes: bytes, owner: owner, seq: seq, catalogHash: catalogHash, catalogSize: Int(size),
                              indexHash: indexHash, issuedAt: issuedAt)
    }

    /// The `seq` for the next publish: one more than the higher of the stored pointer's and this device's highest. Nil
    /// past `maxSeq`.
    public static func nextSeq(stored: UInt64?, localHighest: UInt64?) -> UInt64? {
        let base = max(stored ?? 0, localHighest ?? 0)
        guard base < maxSeq else { return nil }
        return base + 1
    }
}
