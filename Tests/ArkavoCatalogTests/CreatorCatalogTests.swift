import CryptoKit
import Foundation
import Testing
@testable import ArkavoCatalog

struct CreatorCatalogTests {
    static let owner = "5c1f0e7a-2b8d-4c0f-9a51-3f2b6d8e4a10"
    /// Stands in for a metadata ZTDF: the document only carries its bytes. Base64url `enRkZg`.
    static let metadata = Data("ztdf".utf8)

    static func entry(_ contentID: String = "rec-a", version: UInt64 = 1, payload: Character = "1",
                      metadata: Data = metadata) -> CreatorCatalog.Entry {
        CreatorCatalog.Entry(contentID: contentID, version: version, payloadHash: String(repeating: payload, count: 64),
                             payloadSize: 7_342_067, metadata: metadata)
    }

    /// A stand-in for BLAKE3: the envelope and publish checks take the hash function from their caller.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Encoding

    @Test func encodesTheFrozenFormat() throws {
        let data = try CreatorCatalog(owner: Self.owner, entries: [Self.entry()]).encoded()
        let p = String(repeating: "1", count: 64)
        #expect(String(decoding: data, as: UTF8.self) == #"{"entries":[{"contentID":"rec-a","metadata":"enRkZg","payloadHash":"\#(p)","payloadSize":7342067,"version":1}],"owner":"\#(Self.owner)","schema":"arkavo.creator-catalog/2"}"#)
    }

    @Test func encodesAnEmptyCatalog() throws {
        let data = try CreatorCatalog(owner: Self.owner).encoded()
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"entries":[],"owner":"\#(Self.owner)","schema":"arkavo.creator-catalog/2"}"#)
    }

    @Test func roundTripsAndOrdersByContentID() throws {
        let catalog = CreatorCatalog(owner: Self.owner, entries: [
            Self.entry("rec-c", payload: "5", metadata: Data([0xFB, 0xFF, 0x00])), Self.entry("rec-a"),
            Self.entry("rec-B", payload: "3", metadata: Data(repeating: 9, count: CreatorCatalog.maxMetadataSize)),
        ])
        #expect(catalog.entries.map(\.contentID) == ["rec-B", "rec-a", "rec-c"])
        #expect(try CreatorCatalog.decode(catalog.encoded()) == catalog)
    }

    @Test func encodingRefusesWhatDecodingRefuses() {
        #expect(throws: CreatorCatalogError.owner) { try CreatorCatalog(owner: "a..b").encoded() }
        #expect(throws: CreatorCatalogError.duplicateContentID(1)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry(), Self.entry(payload: "3")]).encoded()
        }
        #expect(throws: CreatorCatalogError.metadata(0)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry(metadata: Data())]).encoded()
        }
        #expect(throws: CreatorCatalogError.metadata(0)) {
            try CreatorCatalog(owner: Self.owner,
                               entries: [Self.entry(metadata: Data(count: CreatorCatalog.maxMetadataSize + 1))]).encoded()
        }
        #expect(throws: CreatorCatalogError.version(0)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry(version: 0)]).encoded()
        }
        #expect(throws: CreatorCatalogError.contentID(0)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry("rec a")]).encoded()
        }
    }

    @Test func encodingRefusesMoreThan1000Entries() {
        let entries = (0...1_000).map { index in
            CreatorCatalog.Entry(contentID: "rec-\(index)", version: 1, payloadHash: Self.hex(index), payloadSize: 1,
                                 metadata: Self.metadata)
        }
        #expect(throws: CreatorCatalogError.tooManyEntries) {
            try CreatorCatalog(owner: Self.owner, entries: entries).encoded()
        }
        #expect(throws: Never.self) {
            try CreatorCatalog(owner: Self.owner, entries: Array(entries.dropLast())).encoded()
        }
    }

    @Test func encodingRefusesADocumentOver4MiB() {
        // 70 metadata TDFs at the 64 KiB limit are about 6.1 MB in base64url.
        let entries = (0..<70).map { index in
            CreatorCatalog.Entry(contentID: "rec-\(index)", version: 1, payloadHash: Self.hex(index), payloadSize: 1,
                                 metadata: Data(count: CreatorCatalog.maxMetadataSize))
        }
        #expect(throws: CreatorCatalogError.tooLarge) { try CreatorCatalog(owner: Self.owner, entries: entries).encoded() }
    }

    // MARK: Changes

    @Test func publishingTakesTheNextVersionOnlyForANewPayload() {
        var catalog = CreatorCatalog(owner: Self.owner, entries: [Self.entry(version: 4)])
        #expect(catalog.version(forPublishing: "rec-new", payloadHash: String(repeating: "9", count: 64)) == 1)
        #expect(catalog.version(forPublishing: "rec-a", payloadHash: String(repeating: "1", count: 64)) == 4)
        #expect(catalog.version(forPublishing: "rec-a", payloadHash: String(repeating: "7", count: 64)) == 5)
        catalog.upsert(Self.entry(version: CatalogField.maxVersion))
        #expect(catalog.version(forPublishing: "rec-a", payloadHash: String(repeating: "7", count: 64)) == nil)
    }

    @Test func upsertReplacesAndRemoveDrops() {
        var catalog = CreatorCatalog(owner: Self.owner, entries: [Self.entry("rec-b", payload: "3")])
        catalog.upsert(Self.entry("rec-a"))
        catalog.upsert(Self.entry("rec-c", payload: "5"))
        catalog.upsert(Self.entry("rec-a", version: 2, payload: "7", metadata: Data([1])))
        #expect(catalog.entries.map(\.contentID) == ["rec-a", "rec-b", "rec-c"])
        #expect(catalog.entry(contentID: "rec-a")?.version == 2)
        #expect(catalog.entry(contentID: "rec-a")?.metadata == Data([1]))
        let removed = catalog.remove(contentID: "rec-b")
        let removedAgain = catalog.remove(contentID: "rec-b")
        #expect(removed)
        #expect(!removedAgain)
        #expect(catalog.entries.map(\.contentID) == ["rec-a", "rec-c"])
    }

    @Test func removeAndUpsertDropAllDuplicateContentIDs() {
        var catalog = CreatorCatalog(owner: Self.owner, entries: [
            Self.entry("rec-a", version: 1),
            Self.entry("rec-a", version: 2, payload: "3"),
            Self.entry("rec-b", payload: "5"),
        ])
        let removedFirst = catalog.remove(contentID: "rec-a")
        #expect(removedFirst)
        #expect(catalog.entries.map(\.contentID) == ["rec-b"])
        let removedSecond = catalog.remove(contentID: "rec-a")
        #expect(!removedSecond)

        var duplicated = CreatorCatalog(owner: Self.owner, entries: [
            Self.entry("rec-a", version: 1),
            Self.entry("rec-a", version: 2, payload: "3"),
            Self.entry("rec-b", payload: "5"),
        ])
        duplicated.upsert(Self.entry("rec-a", version: 3, payload: "7"))
        #expect(duplicated.entries.map(\.contentID) == ["rec-a", "rec-b"])
        #expect(duplicated.entry(contentID: "rec-a")?.version == 3)
        #expect(throws: Never.self) { _ = try duplicated.encoded() }
    }

    // MARK: Decoding errors

    @Test func decodingNamesWhatIsWrong() {
        let p = String(repeating: "1", count: 64)
        let good = #"{"contentID":"rec-a","version":1,"payloadHash":"\#(p)","payloadSize":1,"metadata":"enRkZg"}"#
        func doc(_ entries: String) -> Data {
            Data(#"{"schema":"arkavo.creator-catalog/2","owner":"\#(Self.owner)","entries":[\#(entries)]}"#.utf8)
        }
        let cases: [(Data, CreatorCatalogError)] = [
            (Data("[]".utf8), .malformed),
            (Data(#"{"schema":"arkavo.creator-catalog/2","owner":"\#(Self.owner)"}"#.utf8), .keys),
            (Data(#"{"schema":"arkavo.creator-catalog/1","owner":"\#(Self.owner)","entries":[]}"#.utf8), .schema),
            (Data(#"{"schema":"arkavo.creator-catalog/2","owner":"","entries":[]}"#.utf8), .owner),
            (Data(#"{"schema":"arkavo.creator-catalog/2","owner":"\#(Self.owner)","entries":{}}"#.utf8), .entries),
            (doc("7"), .entryKeys(0)),
            (doc(good.replacingOccurrences(of: #","metadata":"enRkZg""#, with: "")), .entryKeys(0)),
            (doc(good.replacingOccurrences(of: #""metadata""#, with: #""metadataHash""#)), .entryKeys(0)),
            (doc(good + "," + good.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0")), .version(1)),
            (doc(good.replacingOccurrences(of: "\"payloadSize\":1", with: "\"payloadSize\":4294967296")), .payloadSize(0)),
            (doc(good.replacingOccurrences(of: p, with: String(repeating: "A", count: 64))), .payloadHash(0)),
        ]
        for (data, error) in cases {
            #expect(throws: error) { try CreatorCatalog.decode(data) }
        }
        // Not canonical unpadded base64url, or empty.
        for metadata in [#""enRkZg==""#, #""enRkZh""#, #""+/8""#, #""""#, "7", "null", #""enRk Zg""#] {
            #expect(throws: CreatorCatalogError.metadata(0), "\(metadata)") {
                try CreatorCatalog.decode(doc(good.replacingOccurrences(of: #""enRkZg""#, with: metadata)))
            }
        }
    }

    @Test func decodingRefusesMoreThan4MiBFirst() throws {
        let data = try CreatorCatalog(owner: Self.owner, entries: [Self.entry()]).encoded()
        let padded = data + Data(repeating: 0x20, count: CreatorCatalog.maxDocumentBytes - data.count)
        #expect(CreatorCatalog.maxDocumentBytes == 4_194_304)
        #expect(throws: Never.self) { try CreatorCatalog.decode(padded) }
        #expect(throws: CreatorCatalogError.tooLarge) { try CreatorCatalog.decode(padded + Data(" ".utf8)) }
    }

    // MARK: The decrypted payload

    @Test func decodesThePayloadForItsOwner() throws {
        let catalog = CreatorCatalog(owner: Self.owner, entries: [Self.entry()])
        #expect(try CreatorCatalog.decode(catalog.encoded(), owner: Self.owner) == catalog)
    }

    @Test func aPayloadIsCheckedForFormatThenOwner() throws {
        let v1 = Data(#"{"schema":"arkavo.creator-catalog/1","owner":"\#(Self.owner)","entries":[]}"#.utf8)
        #expect(throws: CatalogDocumentError.invalid(.schema)) { try CreatorCatalog.decode(v1, owner: Self.owner) }
        let data = try CreatorCatalog(owner: Self.owner, entries: [Self.entry()]).encoded()
        #expect(throws: CatalogDocumentError.ownerMismatch) { try CreatorCatalog.decode(data, owner: "someone-else") }
    }

    // MARK: The index a /2 pointer signs

    /// A `/2` pointer of this catalog's owner signing `indexHash`.
    static func pointer2(indexHash: String) throws -> CatalogPointer {
        try CatalogPointer(owner: owner, seq: 1, catalogHash: CatalogV2Fixture.documentHash, catalogSize: 97,
                           indexHash: indexHash, issuedAt: CatalogV2Fixture.pointerIssuedAt)
    }

    /// The reader's flow: decode the decrypted payload for the pointer's owner, then check the entries against the index
    /// the pointer signs, whatever order the document lists them in.
    @Test func aPayloadMatchesThePointer2ThatSignsItsIndex() throws {
        let entries = Self.twoEntries.map {
            "{\"contentID\":\"\($0.contentID)\",\"version\":\($0.version),\"payloadHash\":\"\($0.payloadHash)\",\"payloadSize\":\($0.payloadSize),\"metadata\":\"enRkZg\"}"
        }
        let payload = Data(#"{"schema":"arkavo.creator-catalog/2","owner":"\#(Self.owner)","entries":[\#(entries.joined(separator: ","))]}"#.utf8)
        let pointer = try Self.pointer2(indexHash: Self.twoIndexHash)
        let catalog = try CreatorCatalog.decode(payload, owner: pointer.owner)
        #expect(throws: Never.self) { try catalog.checkIndexHash(against: pointer) }
        #expect(throws: Never.self) {
            try CreatorCatalog(owner: Self.owner).checkIndexHash(against: Self.pointer2(indexHash: Self.emptyIndexHash))
        }
    }

    @Test func aPointer2ThatSignsAnotherIndexIsAMismatch() throws {
        let catalog = Self.catalog(Self.twoEntries)
        for other in [Self.emptyIndexHash, Self.byteOrderIndexHash, String(repeating: "0", count: 64)] {
            #expect(throws: CatalogDocumentError.indexHashMismatch) {
                try catalog.checkIndexHash(against: Self.pointer2(indexHash: other))
            }
        }
        // One entry's version differs from the signed index.
        var changed = catalog
        changed.upsert(CreatorCatalog.Entry(contentID: "rec-a", version: 4, payloadHash: String(repeating: "aa", count: 32),
                                            payloadSize: 1_024, metadata: Self.metadata))
        #expect(throws: CatalogDocumentError.indexHashMismatch) {
            try changed.checkIndexHash(against: Self.pointer2(indexHash: Self.twoIndexHash))
        }
        // An empty catalog under a pointer that signed two entries.
        #expect(throws: CatalogDocumentError.indexHashMismatch) {
            try CreatorCatalog(owner: Self.owner).checkIndexHash(against: Self.pointer2(indexHash: Self.twoIndexHash))
        }
    }

    /// A `/1` pointer signs no index, so there is nothing to check.
    @Test func aPointer1HasNoIndexToCheck() throws {
        let pointer = try CatalogPointer.decode(CatalogV2Fixture.makePointer(owner: Self.owner))
        #expect(pointer.indexHash == nil)
        #expect(throws: Never.self) { try Self.catalog(Self.twoEntries).checkIndexHash(against: pointer) }
        #expect(throws: Never.self) { try CreatorCatalog(owner: Self.owner).checkIndexHash(against: pointer) }
    }

    @Test func aCatalogTheFormatRefusesIsInvalid() throws {
        let bad = CreatorCatalog(owner: Self.owner, entries: [Self.entry(version: 0)])
        #expect(throws: CatalogDocumentError.invalid(.version(0))) {
            try bad.checkIndexHash(against: Self.pointer2(indexHash: Self.emptyIndexHash))
        }
    }

    // MARK: The index

    @Test func theIndexIsTheEntriesWithoutTheirMetadata() throws {
        let catalog = CreatorCatalog(owner: Self.owner, entries: [Self.entry("rec-b", payload: "3"), Self.entry("rec-a")])
        let index = try catalog.encodedIndex()
        let p1 = String(repeating: "1", count: 64), p3 = String(repeating: "3", count: 64)
        #expect(String(decoding: index, as: UTF8.self) == #"[{"contentID":"rec-a","payloadHash":"\#(p1)","payloadSize":7342067,"version":1},{"contentID":"rec-b","payloadHash":"\#(p3)","payloadSize":7342067,"version":1}]"#)
        #expect(try CreatorCatalog.decodeIndex(index) == catalog.entries.map(CreatorCatalog.IndexEntry.init))
        #expect(String(decoding: try CreatorCatalog(owner: Self.owner).encodedIndex(), as: UTF8.self) == "[]")
    }

    @Test func theIndexRefusesWhatTheDocumentRefuses() {
        #expect(throws: CreatorCatalogError.metadata(0)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry(metadata: Data())]).encodedIndex()
        }
        #expect(throws: CreatorCatalogError.owner) { try CreatorCatalog(owner: ".").encodedIndex() }
        #expect(throws: CreatorCatalogError.malformed) { try CreatorCatalog.decodeIndex(Data("{}".utf8)) }
        let p = String(repeating: "1", count: 64)
        let withMetadata = #"[{"contentID":"rec-a","version":1,"payloadHash":"\#(p)","payloadSize":1,"metadata":"enRkZg"}]"#
        #expect(throws: CreatorCatalogError.entryKeys(0)) { try CreatorCatalog.decodeIndex(Data(withMetadata.utf8)) }
    }

    // MARK: The canonical index hash

    /// The node's `index_hash_vectors` (tdf-iroh-s3 `src/creator_catalog.rs`), which the contract lists under `indexHash`.
    static let emptyIndexHash = "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
    static let twoIndexHash = "03f745d8d08d9e9e11cabf33d85e8beb452eb3a2b2e541f92e1703c1f4152df4"
    static let byteOrderIndexHash = "79129b9fa70e8ab5d0894d07098294de6dec2677c9df538b3eb05df98bd8ef18"

    static func indexEntry(_ contentID: String, version: UInt64, payloadHash: String,
                           payloadSize: UInt64) -> CreatorCatalog.IndexEntry {
        CreatorCatalog.IndexEntry(contentID: contentID, version: version, payloadHash: payloadHash, payloadSize: payloadSize)
    }

    /// "two": `rec-b` (v1, `bb`×32, 2048), then `rec-a` (v3, `aa`×32, 1024).
    static let twoEntries = [
        indexEntry("rec-b", version: 1, payloadHash: String(repeating: "bb", count: 32), payloadSize: 2_048),
        indexEntry("rec-a", version: 3, payloadHash: String(repeating: "aa", count: 32), payloadSize: 1_024),
    ]

    /// "byte-order": entry n, counting from 0 in this order, has hash byte n ×32, size n + 1, v1.
    static let byteOrderEntries = ["a_1", "a@1", "A", "a:1", "a.1", "a-1"].enumerated().map { n, contentID in
        indexEntry(contentID, version: 1, payloadHash: String(repeating: "0\(n)", count: 32), payloadSize: UInt64(n + 1))
    }

    /// The catalog listing `entries`, each with the same stand-in metadata.
    static func catalog(_ entries: [CreatorCatalog.IndexEntry]) -> CreatorCatalog {
        CreatorCatalog(owner: owner, entries: entries.map {
            CreatorCatalog.Entry(contentID: $0.contentID, version: $0.version, payloadHash: $0.payloadHash,
                                 payloadSize: $0.payloadSize, metadata: metadata)
        })
    }

    @Test func theCanonicalIndexOfNoEntriesIsAnEmptyArray() throws {
        #expect(String(decoding: CreatorCatalog.canonicalIndex([]), as: UTF8.self) == "[]")
        #expect(CreatorCatalog.indexHash([]) == Self.emptyIndexHash)
        #expect(try CreatorCatalog(owner: Self.owner).canonicalIndexHash() == Self.emptyIndexHash)
    }

    @Test func theCanonicalIndexSortsEntriesAndWritesKeysInTheContractsOrder() throws {
        let a = String(repeating: "aa", count: 32), b = String(repeating: "bb", count: 32)
        #expect(String(decoding: CreatorCatalog.canonicalIndex(Self.twoEntries), as: UTF8.self)
            == #"[{"contentID":"rec-a","version":3,"payloadHash":"\#(a)","payloadSize":1024},{"contentID":"rec-b","version":1,"payloadHash":"\#(b)","payloadSize":2048}]"#)
        #expect(CreatorCatalog.indexHash(Self.twoEntries) == Self.twoIndexHash)
        #expect(try Self.catalog(Self.twoEntries).canonicalIndexHash() == Self.twoIndexHash)
    }

    /// UTF-8 byte order: `A` < `a-1` < `a.1` < `a:1` < `a@1` < `a_1`.
    @Test func theCanonicalIndexComparesContentIDsAsUTF8Bytes() throws {
        let canonical = String(decoding: CreatorCatalog.canonicalIndex(Self.byteOrderEntries), as: UTF8.self)
        let positions = ["A", "a-1", "a.1", "a:1", "a@1", "a_1"].map {
            canonical.range(of: #""contentID":"\#($0)""#)?.lowerBound
        }
        #expect(!positions.contains(nil))
        #expect(positions.compactMap(\.self) == positions.compactMap(\.self).sorted())
        #expect(canonical.hasPrefix(#"[{"contentID":"A","version":1,"payloadHash":"0202"#))
        #expect(CreatorCatalog.indexHash(Self.byteOrderEntries) == Self.byteOrderIndexHash)
        #expect(try Self.catalog(Self.byteOrderEntries).canonicalIndexHash() == Self.byteOrderIndexHash)
    }

    /// The hash covers the four index fields only: not the metadata, and not the order the entries were given in.
    @Test func theCanonicalIndexHashIgnoresMetadataAndEntryOrder() throws {
        let one = CreatorCatalog(owner: Self.owner, entries: [Self.entry("rec-b", payload: "3"), Self.entry("rec-a")])
        let other = CreatorCatalog(owner: Self.owner, entries: [
            Self.entry("rec-a", metadata: Data([1, 2, 3])), Self.entry("rec-b", payload: "3", metadata: Data([4])),
        ])
        #expect(try one.canonicalIndexHash() == other.canonicalIndexHash())
        #expect(try one.canonicalIndexHash() == CreatorCatalog.indexHash(CreatorCatalog.decodeIndex(one.encodedIndex())))
        let changed = CreatorCatalog(owner: Self.owner, entries: [Self.entry("rec-b", payload: "3"),
                                                                  Self.entry("rec-a", version: 2)])
        #expect(try one.canonicalIndexHash() != changed.canonicalIndexHash())
    }

    /// Like `encodedIndex()`, it throws the error the document's encoding would, so it never hashes entries the node
    /// refuses.
    @Test func theCanonicalIndexHashRefusesWhatTheDocumentRefuses() {
        #expect(throws: CreatorCatalogError.contentID(0)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry("rec\"a")]).canonicalIndexHash()
        }
        #expect(throws: CreatorCatalogError.version(0)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry(version: 0)]).canonicalIndexHash()
        }
        #expect(throws: CreatorCatalogError.duplicateContentID(1)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry(), Self.entry(payload: "3")]).canonicalIndexHash()
        }
        #expect(throws: CreatorCatalogError.metadata(0)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry(metadata: Data())]).canonicalIndexHash()
        }
        #expect(throws: CreatorCatalogError.owner) { try CreatorCatalog(owner: ".").canonicalIndexHash() }
    }

    static func hex(_ value: Int) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: 64 - text.count) + text
    }
}
