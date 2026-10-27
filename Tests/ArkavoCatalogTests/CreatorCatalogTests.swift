import CryptoKit
import Foundation
import Testing
@testable import ArkavoCatalog

struct CreatorCatalogTests {
    static let owner = "5c1f0e7a-2b8d-4c0f-9a51-3f2b6d8e4a10"

    static func entry(_ contentID: String = "rec-a", version: UInt64 = 1, payload: Character = "1",
                      metadata: Character = "2", metadataSize: Int = 2_148) -> CreatorCatalog.Entry {
        CreatorCatalog.Entry(contentID: contentID, version: version, payloadHash: String(repeating: payload, count: 64),
                             payloadSize: 7_342_067, metadataHash: String(repeating: metadata, count: 64),
                             metadataSize: metadataSize)
    }

    /// A stand-in for BLAKE3: `verify` takes the hash function from its caller.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Encoding

    @Test func encodesTheFrozenFormat() throws {
        let data = try CreatorCatalog(owner: Self.owner, entries: [Self.entry()]).encoded()
        let p = String(repeating: "1", count: 64), m = String(repeating: "2", count: 64)
        #expect(String(decoding: data, as: UTF8.self) == #"{"entries":[{"contentID":"rec-a","metadataHash":"\#(m)","metadataSize":2148,"payloadHash":"\#(p)","payloadSize":7342067,"version":1}],"owner":"\#(Self.owner)","schema":"arkavo.creator-catalog/2"}"#)
    }

    @Test func encodesAnEmptyCatalog() throws {
        let data = try CreatorCatalog(owner: Self.owner).encoded()
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"entries":[],"owner":"\#(Self.owner)","schema":"arkavo.creator-catalog/2"}"#)
    }

    @Test func roundTripsAndOrdersByContentID() throws {
        let catalog = CreatorCatalog(owner: Self.owner, entries: [
            Self.entry("rec-c", payload: "5", metadata: "6"), Self.entry("rec-a"), Self.entry("rec-B", payload: "3", metadata: "4"),
        ])
        #expect(catalog.entries.map(\.contentID) == ["rec-B", "rec-a", "rec-c"])
        #expect(try CreatorCatalog.decode(catalog.encoded()) == catalog)
    }

    @Test func encodingRefusesWhatDecodingRefuses() {
        #expect(throws: CreatorCatalogError.owner) { try CreatorCatalog(owner: "a..b").encoded() }
        #expect(throws: CreatorCatalogError.duplicateContentID(1)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry(), Self.entry(payload: "3", metadata: "4")]).encoded()
        }
        #expect(throws: CreatorCatalogError.duplicateMetadataHash(1)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry("rec-a"), Self.entry("rec-b", payload: "3")]).encoded()
        }
        #expect(throws: CreatorCatalogError.metadataHashIsPayloadHash(0)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry(payload: "1", metadata: "1")]).encoded()
        }
        #expect(throws: CreatorCatalogError.metadataSize(0)) {
            try CreatorCatalog(owner: Self.owner, entries: [Self.entry(metadataSize: 65_537)]).encoded()
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
                                 metadataHash: Self.hex(index + 10_000), metadataSize: 1)
        }
        #expect(throws: CreatorCatalogError.tooManyEntries) {
            try CreatorCatalog(owner: Self.owner, entries: entries).encoded()
        }
        #expect(throws: Never.self) {
            try CreatorCatalog(owner: Self.owner, entries: Array(entries.dropLast())).encoded()
        }
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
        var catalog = CreatorCatalog(owner: Self.owner, entries: [Self.entry("rec-b", payload: "3", metadata: "4")])
        catalog.upsert(Self.entry("rec-a"))
        catalog.upsert(Self.entry("rec-c", payload: "5", metadata: "6"))
        catalog.upsert(Self.entry("rec-a", version: 2, payload: "7", metadata: "8"))
        #expect(catalog.entries.map(\.contentID) == ["rec-a", "rec-b", "rec-c"])
        #expect(catalog.entry(contentID: "rec-a")?.version == 2)
        let removed = catalog.remove(contentID: "rec-b")
        let removedAgain = catalog.remove(contentID: "rec-b")
        #expect(removed)
        #expect(!removedAgain)
        #expect(catalog.entries.map(\.contentID) == ["rec-a", "rec-c"])
    }

    // MARK: Decoding errors

    @Test func decodingNamesWhatIsWrong() {
        let p = String(repeating: "1", count: 64), m = String(repeating: "2", count: 64)
        let good = #"{"contentID":"rec-a","version":1,"payloadHash":"\#(p)","payloadSize":1,"metadataHash":"\#(m)","metadataSize":1}"#
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
            (doc(good + "," + good.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0")), .version(1)),
            (doc(good.replacingOccurrences(of: "\"payloadSize\":1", with: "\"payloadSize\":4294967296")), .payloadSize(0)),
            (doc(good.replacingOccurrences(of: p, with: String(repeating: "A", count: 64))), .payloadHash(0)),
            (doc(good.replacingOccurrences(of: m, with: "x")), .metadataHash(0)),
        ]
        for (data, error) in cases {
            #expect(throws: error) { try CreatorCatalog.decode(data) }
        }
    }

    @Test func decodingRefusesMoreThan524288BytesFirst() throws {
        let data = try CreatorCatalog(owner: Self.owner, entries: [Self.entry()]).encoded()
        let padded = data + Data(repeating: 0x20, count: CreatorCatalog.maxDocumentBytes - data.count)
        #expect(throws: Never.self) { try CreatorCatalog.decode(padded) }
        #expect(throws: CreatorCatalogError.tooLarge) { try CreatorCatalog.decode(padded + Data(" ".utf8)) }
    }

    // MARK: Verification against the pointer

    static func pointer(for data: Data, owner: String = owner, size: Int? = nil) throws -> CatalogPointer {
        try CatalogPointer(owner: owner, seq: 1, catalogHash: sha256(data), catalogSize: size ?? data.count,
                           issuedAt: Date(timeIntervalSince1970: 1_792_371_723))
    }

    @Test func verifiesTheDocumentThePointerNames() throws {
        let catalog = CreatorCatalog(owner: Self.owner, entries: [Self.entry()])
        let data = try catalog.encoded()
        #expect(try CreatorCatalog.verify(data, pointer: Self.pointer(for: data), blake3: Self.sha256) == catalog)
    }

    @Test func verificationRunsItsChecksInOrder() throws {
        let data = try CreatorCatalog(owner: Self.owner, entries: [Self.entry()]).encoded()
        let pointer = try Self.pointer(for: data)
        let oversized = data + Data(repeating: 0x20, count: CreatorCatalog.maxDocumentBytes)
        #expect(throws: CatalogDocumentError.tooLarge) {
            try CreatorCatalog.verify(oversized, pointer: pointer, blake3: Self.sha256)
        }
        #expect(throws: CatalogDocumentError.sizeMismatch) {
            try CreatorCatalog.verify(data + Data(" ".utf8), pointer: pointer, blake3: Self.sha256)
        }
        var flipped = data
        flipped[flipped.count - 3] ^= 0x01
        #expect(throws: CatalogDocumentError.hashMismatch) {
            try CreatorCatalog.verify(flipped, pointer: pointer, blake3: Self.sha256)
        }
        let v1 = Data(#"{"schema":"arkavo.creator-catalog/1","owner":"\#(Self.owner)","entries":[]}"#.utf8)
        #expect(throws: CatalogDocumentError.invalid(.schema)) {
            try CreatorCatalog.verify(v1, pointer: Self.pointer(for: v1), blake3: Self.sha256)
        }
        #expect(throws: CatalogDocumentError.ownerMismatch) {
            try CreatorCatalog.verify(data, pointer: Self.pointer(for: data, owner: "someone-else"), blake3: Self.sha256)
        }
    }

    static func hex(_ value: Int) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: 64 - text.count) + text
    }
}
