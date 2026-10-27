import Foundation

/// A creator's `arkavo.catalog-pointer/1`: the small document their passkey signs, naming their current catalog
/// document by BLAKE3 hash and size.
///
/// One strict JSON object of 1 to 1,024 bytes with exactly `schema`, `owner`, `seq`, `catalogHash`, `catalogSize` and
/// `issuedAt`. `bytes` are the bytes the passkey signed. They are carried base64url-encoded and never re-serialized:
/// `decode` keeps the bytes exactly as received, and the builder writes them once. `issuedAt` is checked for its format
/// only and is never compared with the clock.
public struct CatalogPointer: Sendable, Equatable {
    public static let schema = "arkavo.catalog-pointer/1"
    public static let maxBytes = 1_024
    public static let maxSeq: UInt64 = 9_007_199_254_740_991
    private static let keys: Set<String> = ["schema", "owner", "seq", "catalogHash", "catalogSize", "issuedAt"]

    /// The signed bytes.
    public let bytes: Data
    public let owner: String
    public let seq: UInt64
    /// BLAKE3 of the catalog document, 64 lowercase hex characters.
    public let catalogHash: String
    /// The catalog document's length, 1 to `CreatorCatalog.maxDocumentBytes`.
    public let catalogSize: Int
    /// Whole seconds.
    public let issuedAt: Date

    /// The pointer to sign. `issuedAt` is rounded down to the second. Throws `CatalogBundleError.pointer` when a value
    /// breaks the format, so the bytes never need JSON escaping.
    public init(owner: String, seq: UInt64, catalogHash: String, catalogSize: Int,
                issuedAt: Date) throws(CatalogBundleError) {
        guard CatalogField.isValidSubject(owner), (1...Self.maxSeq).contains(seq),
              CatalogField.isLowercaseHexDigest(catalogHash), (1...CreatorCatalog.maxDocumentBytes).contains(catalogSize),
              let stamp = CatalogField.timestamp(issuedAt) else { throw .pointer }
        let bytes = Data(#"{"schema":"\#(Self.schema)","owner":"\#(owner)","seq":\#(seq),"catalogHash":"\#(catalogHash)","catalogSize":\#(catalogSize),"issuedAt":"\#(stamp)"}"#.utf8)
        guard bytes.count <= Self.maxBytes else { throw .pointer }
        self.init(bytes: bytes, owner: owner, seq: seq, catalogHash: catalogHash, catalogSize: catalogSize,
                  issuedAt: Date(timeIntervalSince1970: issuedAt.timeIntervalSince1970.rounded(.down)))
    }

    private init(bytes: Data, owner: String, seq: UInt64, catalogHash: String, catalogSize: Int, issuedAt: Date) {
        self.bytes = bytes
        self.owner = owner
        self.seq = seq
        self.catalogHash = catalogHash
        self.catalogSize = catalogSize
        self.issuedAt = issuedAt
    }

    /// Throws `CatalogBundleError.pointer` for anything that is not a valid pointer. Surrounding whitespace is allowed.
    /// The caller compares `owner` with the subject it asked for.
    public static func decode(_ bytes: Data) throws(CatalogBundleError) -> CatalogPointer {
        guard (1...maxBytes).contains(bytes.count), let root = StrictJSON.parse(bytes)?.object,
              Set(root.keys) == keys, root["schema"] == .string(schema),
              let owner = root["owner"]?.string, CatalogField.isValidSubject(owner),
              let seq = CatalogField.integer(root["seq"], in: 1...maxSeq),
              let catalogHash = root["catalogHash"]?.string, CatalogField.isLowercaseHexDigest(catalogHash),
              let size = CatalogField.integer(root["catalogSize"], in: 1...UInt64(CreatorCatalog.maxDocumentBytes)),
              let stamp = root["issuedAt"]?.string, let issuedAt = CatalogField.timestamp(stamp) else {
            throw .pointer
        }
        return CatalogPointer(bytes: bytes, owner: owner, seq: seq, catalogHash: catalogHash, catalogSize: Int(size),
                              issuedAt: issuedAt)
    }

    /// The `seq` for the next publish: one more than the higher of the stored pointer's and this device's highest. Nil
    /// past `maxSeq`.
    public static func nextSeq(stored: UInt64?, localHighest: UInt64?) -> UInt64? {
        let base = max(stored ?? 0, localHighest ?? 0)
        guard base < maxSeq else { return nil }
        return base + 1
    }
}
