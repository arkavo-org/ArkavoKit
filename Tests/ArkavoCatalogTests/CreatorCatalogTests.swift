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

    static func hex(_ value: Int) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: 64 - text.count) + text
    }
}
