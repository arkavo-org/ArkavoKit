import Foundation
import Testing
@testable import ArkavoCatalog

struct CatalogEntryMetadataTests {
    static let attribute = "https://patreon.arkavo.com/attr/campaign/value/12345678"
    static let publishedAt = Date(timeIntervalSince1970: 1_792_371_723)  // 2026-10-19T01:02:03Z

    static func metadata(contentID: String = "rec-a", version: UInt64 = 1, payload: Character = "1",
                         title: String = "Studio session", publishedAt: Date = publishedAt,
                         attributes: [String] = [attribute]) -> CatalogEntryMetadata {
        CatalogEntryMetadata(contentID: contentID, version: version, payloadHash: String(repeating: payload, count: 64),
                             title: title, publishedAt: publishedAt, attributeFQNs: attributes)
    }

    @Test func theMimeTypeIsTheNodes() {
        #expect(CatalogEntryMetadata.mimeType == "application/vnd.arkavo.catalog-entry+json")
    }

    @Test func encodesTheFrozenFormat() throws {
        let p = String(repeating: "1", count: 64)
        #expect(String(decoding: try Self.metadata().encoded(), as: UTF8.self)
            == #"{"attributeFQNs":["\#(Self.attribute)"],"contentID":"rec-a","payloadHash":"\#(p)","publishedAt":"2026-10-19T01:02:03Z","title":"Studio session","version":1}"#)
    }

    @Test func roundTripsAnyTitle() throws {
        for title in ["Studio session", "Line\nTwo \"quoted\" é 😀", "a/b\\c", "\u{0}\u{1F}", String(repeating: "😀", count: 128)] {
            let metadata = Self.metadata(title: title)
            #expect(try CatalogEntryMetadata.decode(metadata.encoded()) == metadata, "\(title.debugDescription)")
        }
    }

    @Test func publishedAtIsWholeSeconds() throws {
        let metadata = Self.metadata(publishedAt: Self.publishedAt.addingTimeInterval(0.75))
        #expect(metadata.publishedAt == Self.publishedAt)
        #expect(try CatalogEntryMetadata.decode(metadata.encoded()).publishedAt == Self.publishedAt)
    }

    @Test func encodingRefusesWhatDecodingRefuses() {
        #expect(throws: CatalogEntryMetadataError.title) { try Self.metadata(title: "").encoded() }
        #expect(throws: CatalogEntryMetadataError.title) {
            try Self.metadata(title: String(repeating: "t", count: 513)).encoded()
        }
        #expect(throws: CatalogEntryMetadataError.version) { try Self.metadata(version: 0).encoded() }
        #expect(throws: CatalogEntryMetadataError.contentID) { try Self.metadata(contentID: "a..b").encoded() }
        #expect(throws: CatalogEntryMetadataError.payloadHash) { try Self.metadata(payload: "G").encoded() }
        #expect(throws: CatalogEntryMetadataError.attributeFQNs) {
            try Self.metadata(attributes: ["http://example.com"]).encoded()
        }
        #expect(throws: CatalogEntryMetadataError.attributeFQNs) {
            try Self.metadata(attributes: (0...32).map { "\(Self.attribute)\($0)" }).encoded()
        }
        #expect(throws: CatalogEntryMetadataError.publishedAt) {
            try Self.metadata(publishedAt: Date(timeIntervalSince1970: 253_402_300_800)).encoded()
        }
    }

    @Test func decodingNamesWhatIsWrong() throws {
        let text = String(decoding: try Self.metadata().encoded(), as: UTF8.self)
        let cases: [(String, CatalogEntryMetadataError)] = [
            ("[]", .malformed),
            (text.replacingOccurrences(of: #""title":"Studio session","#, with: ""), .keys),
            (text.replacingOccurrences(of: #""version":1"#, with: #""version":1,"extra":1"#), .keys),
            (text.replacingOccurrences(of: #""Studio session""#, with: "null"), .title),
            (text.replacingOccurrences(of: "2026-10-19T01:02:03Z", with: "2026-10-19T01:02:03.0Z"), .publishedAt),
        ]
        for (text, error) in cases {
            #expect(throws: error) { try CatalogEntryMetadata.decode(Data(text.utf8)) }
        }
        #expect(throws: CatalogEntryMetadataError.tooLarge) {
            try CatalogEntryMetadata.decode(Data(text.utf8) + Data(repeating: 0x20, count: 65_536))
        }
    }

    @Test func bindsOnlyToItsOwnEntry() {
        let entry = CreatorCatalog.Entry(contentID: "rec-a", version: 3, payloadHash: String(repeating: "1", count: 64),
                                         payloadSize: 10, metadata: Data([1]))
        #expect(Self.metadata(version: 3).isBound(to: entry))
        #expect(!Self.metadata(contentID: "rec-b", version: 3).isBound(to: entry))
        #expect(!Self.metadata(version: 2).isBound(to: entry))
        #expect(!Self.metadata(version: 3, payload: "9").isBound(to: entry))
    }
}
