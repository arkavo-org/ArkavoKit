import Foundation
import Testing
@testable import ArkavoCatalog

struct CatalogEnvelopeTests {
    static let owner = CreatorCatalogTests.owner
    /// Stands in for the ZTDF bytes: the envelope's checks see only its bytes.
    static let envelope = Data("PK\u{3}\u{4} envelope bytes".utf8)

    static func pointer(for envelope: Data = envelope, owner: String = owner) throws -> CatalogPointer {
        try CatalogPointer(owner: owner, seq: 1, catalogHash: CreatorCatalogTests.sha256(envelope),
                           catalogSize: envelope.count, issuedAt: Date(timeIntervalSince1970: 1_792_371_723))
    }

    @Test func theConstantsAreTheNodes() {
        #expect(CatalogEnvelope.mimeType == "application/vnd.arkavo.creator-catalog+json")
        #expect(CatalogEnvelope.maxBytes == 524_288)
        #expect(CatalogEnvelope.campaignAttribute(campaignID: "123")
            == "https://patreon.arkavo.com/attr/campaign/value/123")
        #expect(CatalogEnvelope.creatorAttribute(subject: Self.owner)
            == "https://arkavo.net/attr/creator/value/\(Self.owner)")
    }

    @Test func anEnvelopeCarriesOneCampaignOrItsOwnersCreatorAttribute() {
        for attribute in ["https://patreon.arkavo.com/attr/campaign/value/12345678",
                          "https://patreon.arkavo.com/attr/campaign/value/a_B-9",
                          "https://arkavo.net/attr/creator/value/\(Self.owner)"] {
            #expect(CatalogEnvelope.isEnvelopeAttribute(attribute, owner: Self.owner), "\(attribute)")
        }
        for attribute in ["https://patreon.arkavo.com/attr/campaign/value/",
                          "https://patreon.arkavo.com/attr/campaign/value/1/tier",
                          "https://patreon.arkavo.com/attr/tier/value/1",
                          "https://arkavo.net/attr/creator/value/someone-else",
                          "https://arkavo.net/attr/creator/value/\(Self.owner)x",
                          "https://arkavo.net/attr/creator/value/",
                          "http://patreon.arkavo.com/attr/campaign/value/1"] {
            #expect(!CatalogEnvelope.isEnvelopeAttribute(attribute, owner: Self.owner), "\(attribute)")
        }
    }

    // MARK: Verification against the pointer

    @Test func verifiesTheEnvelopeThePointerNames() throws {
        let pointer = try Self.pointer()
        #expect(throws: Never.self) {
            try CatalogEnvelope.verify(Self.envelope, pointer: pointer, blake3: CreatorCatalogTests.sha256)
        }
    }

    @Test func verificationRunsItsChecksInOrder() throws {
        let pointer = try Self.pointer()
        let oversized = Self.envelope + Data(repeating: 0, count: CatalogEnvelope.maxBytes)
        #expect(throws: CatalogDocumentError.tooLarge) {
            try CatalogEnvelope.verify(oversized, pointer: pointer, blake3: CreatorCatalogTests.sha256)
        }
        #expect(throws: CatalogDocumentError.sizeMismatch) {
            try CatalogEnvelope.verify(Self.envelope + Data([0]), pointer: pointer, blake3: CreatorCatalogTests.sha256)
        }
        var flipped = Self.envelope
        flipped[flipped.count - 1] ^= 0x01
        #expect(throws: CatalogDocumentError.hashMismatch) {
            try CatalogEnvelope.verify(flipped, pointer: pointer, blake3: CreatorCatalogTests.sha256)
        }
    }

    // MARK: The publish request

    static func bundle(for envelope: Data = envelope, owner: String = owner) throws -> CatalogBundle {
        try CatalogBundle(pointer: pointer(for: envelope, owner: owner).bytes, credentialID: Data([1]),
                          authenticatorData: Data([2]), clientDataJSON: Data([3]), signature: Data([4]),
                          attestation: Data([5]))
    }

    static let catalog = CreatorCatalog(owner: owner, entries: [CreatorCatalogTests.entry()])

    @Test func theBodyIsBundleDocumentAndIndex() throws {
        let bundle = try Self.bundle()
        let body = try CatalogPublishRequest.body(envelope: Self.envelope, bundle: bundle, catalog: Self.catalog,
                                                  blake3: CreatorCatalogTests.sha256)
        let root = try #require(StrictJSON.parse(body)?.object)
        #expect(Set(root.keys) == ["bundle", "document", "index"])
        #expect(root["document"]?.string.flatMap(Base64URL.decode) == Self.envelope)
        let bundleJSON = try #require(String(data: bundle.encoded(), encoding: .utf8))
        let indexJSON = String(decoding: try Self.catalog.encodedIndex(), as: UTF8.self)
        #expect(String(decoding: body, as: UTF8.self)
            == #"{"bundle":\#(bundleJSON),"document":"\#(Base64URL.encode(Self.envelope))","index":\#(indexJSON)}"#)
        #expect(try CatalogBundle.decode(bundle.encoded()) == bundle)
    }

    @Test func theBodyRefusesAMismatchedPointer() throws {
        #expect(throws: CatalogPublishRequestError.pointerMismatch) {
            try CatalogPublishRequest.body(envelope: Self.envelope + Data([0]), bundle: Self.bundle(),
                                           catalog: Self.catalog, blake3: CreatorCatalogTests.sha256)
        }
        var other = Self.envelope
        other[0] ^= 0x01
        #expect(throws: CatalogPublishRequestError.pointerMismatch) {
            try CatalogPublishRequest.body(envelope: other, bundle: Self.bundle(), catalog: Self.catalog,
                                           blake3: CreatorCatalogTests.sha256)
        }
        #expect(throws: CatalogPublishRequestError.pointerMismatch) {
            try CatalogPublishRequest.body(envelope: Self.envelope, bundle: Self.bundle(owner: "someone-else"),
                                           catalog: Self.catalog, blake3: CreatorCatalogTests.sha256)
        }
    }

    @Test func theBodyRefusesABadEnvelopeOrIndex() throws {
        #expect(throws: CatalogPublishRequestError.envelopeSize) {
            try CatalogPublishRequest.body(envelope: Data(), bundle: Self.bundle(), catalog: Self.catalog,
                                           blake3: CreatorCatalogTests.sha256)
        }
        let bad = CreatorCatalog(owner: Self.owner, entries: [CreatorCatalogTests.entry(version: 0)])
        #expect(throws: CatalogPublishRequestError.index(.version(0))) {
            try CatalogPublishRequest.body(envelope: Self.envelope, bundle: Self.bundle(), catalog: bad,
                                           blake3: CreatorCatalogTests.sha256)
        }
    }

    @Test func theBodyIsAtMostOneMebibyte() throws {
        // A full envelope and a full index: 524,288 bytes in base64url plus 1,000 entries is more than 1 MiB.
        let envelope = Data(repeating: 7, count: CatalogEnvelope.maxBytes)
        let entries = (0..<1_000).map { index in
            CreatorCatalog.Entry(contentID: String(repeating: "c", count: 200) + "\(index)", version: 1,
                                 payloadHash: CreatorCatalogTests.hex(index), payloadSize: 1,
                                 metadataHash: CreatorCatalogTests.hex(index + 10_000), metadataSize: 1)
        }
        let catalog = CreatorCatalog(owner: Self.owner, entries: entries)
        #expect(throws: CatalogPublishRequestError.tooLarge) {
            try CatalogPublishRequest.body(envelope: envelope, bundle: Self.bundle(for: envelope), catalog: catalog,
                                           blake3: CreatorCatalogTests.sha256)
        }
    }
}
