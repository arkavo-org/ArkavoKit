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
        #expect(CatalogEnvelope.maxBytes == 4_194_304)
        #expect(CatalogEnvelope.campaignAttribute(campaignID: "123")
            == "https://patreon.arkavo.com/attr/campaign/value/123")
        #expect(CatalogEnvelope.creatorAttribute(subject: Self.owner)
            == "https://arkavo.net/attr/creator/value/\(Self.owner)")
    }

    @Test func anEnvelopeCarriesOneCampaignOrItsOwnersCreatorAttribute() {
        for attribute in ["https://patreon.arkavo.com/attr/campaign/value/12345678",
                          "https://patreon.arkavo.com/attr/campaign/value/0",
                          "https://arkavo.net/attr/creator/value/\(Self.owner)"] {
            #expect(CatalogEnvelope.isEnvelopeAttribute(attribute, owner: Self.owner), "\(attribute)")
        }
        for attribute in ["https://patreon.arkavo.com/attr/campaign/value/",
                          "https://patreon.arkavo.com/attr/campaign/value/a_B-9",
                          "https://patreon.arkavo.com/attr/campaign/value/123a",
                          "https://patreon.arkavo.com/attr/campaign/value/-1",
                          "https://patreon.arkavo.com/attr/campaign/value/1/tier",
                          "https://patreon.arkavo.com/attr/tier/value/1",
                          "https://arkavo.net/attr/creator/value/someone-else",
                          "https://arkavo.net/attr/creator/value/\(Self.owner)x",
                          "https://arkavo.net/attr/creator/value/",
                          "http://patreon.arkavo.com/attr/campaign/value/1"] {
            #expect(!CatalogEnvelope.isEnvelopeAttribute(attribute, owner: Self.owner), "\(attribute)")
        }
    }

    /// Identity mints the creator value with the bare lowercase account UUID, so no other owner can carry it.
    @Test func theCreatorValueNeedsABareLowercaseUUIDOwner() {
        let uuid = "0715eaff-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
        #expect(CatalogEnvelope.isEnvelopeAttribute(CatalogEnvelope.creatorAttribute(subject: uuid), owner: uuid))
        for owner in ["arkavo:\(uuid)", uuid.uppercased(), "0715eaff1c2d4e5f8a9b0c1d2e3f4a5b", "creator-1",
                      "0715eaff-1c2d-4e5f-8a9b-0c1d2e3f4a5", "0715eaff-1c2d-4e5f-8a9b-0c1d2e3f4a5g"] {
            #expect(!CatalogEnvelope.isEnvelopeAttribute(CatalogEnvelope.creatorAttribute(subject: owner), owner: owner),
                    "\(owner)")
        }
        // A campaign value doesn't depend on the owner.
        #expect(CatalogEnvelope.isEnvelopeAttribute(CatalogEnvelope.campaignAttribute(campaignID: "42"), owner: "creator-1"))
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

    @Test func theLimitIsTheNodes() {
        #expect(CatalogPublishRequest.maxBytes == 10_485_760)
    }

    /// The largest envelope with the largest index, 1,000 entries with 256-byte contentIDs and the largest numbers, is
    /// about 6 MB and fits under the node's 10 MiB.
    @Test func theLargestCatalogFits() throws {
        let envelope = Data(repeating: 7, count: CatalogEnvelope.maxBytes)
        let entries = (0..<1_000).map { index in
            let suffix = String(index)
            return CreatorCatalog.Entry(
                contentID: String(repeating: "c", count: CatalogField.maxContentIDBytes - suffix.count) + suffix,
                version: CatalogField.maxVersion, payloadHash: CreatorCatalogTests.hex(index),
                payloadSize: CatalogField.maxPayloadSize, metadata: CreatorCatalogTests.metadata)
        }
        let catalog = CreatorCatalog(owner: Self.owner, entries: entries)
        let body = try CatalogPublishRequest.body(envelope: envelope, bundle: Self.bundle(for: envelope),
                                                  catalog: catalog, blake3: CreatorCatalogTests.sha256)
        #expect(body.count > 5_000_000)
        #expect(body.count <= CatalogPublishRequest.maxBytes)
    }
}
