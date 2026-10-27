import Foundation
import Testing
import ZIPFoundation
@testable import ArkavoCatalog

/// The checks before a publish: the node's envelope checks (#39), and the metadata checks it no longer runs, mirrored from
/// tdf-iroh-s3's `catalog_metadata.rs` tests, on the metadata TDFs inside the entries. Plus the design's own rules: fresh
/// policy uuids, and an envelope with no dissemination list.
struct CatalogPublicationCheckTests {
    static let kas = "https://platform.arkavo.net/kas"
    static let campaign = "https://patreon.arkavo.com/attr/campaign/value/12345678"
    static let other = "https://patreon.arkavo.com/attr/campaign/value/99"

    static func manifest(_ policy: Any, kas: [String] = [kas], mimeType: String? = CatalogEntryMetadata.mimeType) -> Data {
        let policyJSON = try! JSONSerialization.data(withJSONObject: policy)
        var payload: [String: Any] = ["type": "reference", "url": "0.payload", "protocol": "zip", "isEncrypted": true]
        payload["mimeType"] = mimeType
        let manifest: [String: Any] = [
            "payload": payload,
            "encryptionInformation": [
                "type": "split",
                "policy": policyJSON.base64EncodedString(),
                "keyAccess": kas.map { ["type": "wrapped", "url": $0, "protocol": "kas", "wrappedKey": "AAAA"] },
                "method": ["algorithm": "AES-256-GCM", "isStreamable": true, "iv": ""],
            ] as [String: Any],
        ]
        return try! JSONSerialization.data(withJSONObject: manifest)
    }

    static func recordingPolicy(uuid: String = "0b0e6f7c-0000-4000-8000-000000000001") -> [String: Any] {
        ["uuid": uuid, "body": ["dataAttributes": [["attribute": campaign]], "dissem": [String]()],
         "arkavo:classification": "general"]
    }

    static func metadataPolicy(uuid: Any = "0b0e6f7c-0000-4000-8000-000000000002",
                               attributes: Any = [["attribute": campaign]]) -> [String: Any] {
        ["uuid": uuid, "body": ["dataAttributes": attributes, "dissem": [String]()]]
    }

    static func read(_ data: Data) -> CatalogTDFManifest { CatalogTDFManifest(manifestJSON: data)! }

    static func check(_ metadata: Data, recording: Data = manifest(recordingPolicy(), mimeType: "video/mp4"))
        -> CatalogMetadataRefusal? {
        do {
            try CatalogPublicationCheck.check(metadata: read(metadata), recording: read(recording))
            return nil
        } catch {
            return error
        }
    }

    @Test func theSamePolicyAndKASFit() {
        #expect(Self.check(Self.manifest(Self.metadataPolicy())) == nil)
    }

    @Test func onlyUUIDAndBodyAreAllowed() {
        for key in ["arkavo:classification", "arkavo:components", "extra"] {
            var policy = Self.metadataPolicy()
            policy[key] = "x"
            #expect(Self.check(Self.manifest(policy)) == .extraPolicyKeys, "\(key)")
        }
        for key in ["uuid", "body"] {
            var policy = Self.metadataPolicy()
            policy[key] = nil
            #expect(Self.check(Self.manifest(policy)) == .extraPolicyKeys, "\(key)")
        }
    }

    @Test func thePolicyIDIsANonEmptyString() {
        for id: Any in ["", 7, NSNull()] {
            #expect(Self.check(Self.manifest(Self.metadataPolicy(uuid: id))) == .noPolicyID, "\(id)")
        }
    }

    @Test func metadataMustHaveTheCatalogEntryType() {
        for mimeType: String? in ["application/octet-stream", "application/json", "", nil] {
            #expect(Self.check(Self.manifest(Self.metadataPolicy(), mimeType: mimeType)) == .notCatalogMetadata)
        }
    }

    @Test func attributesCompareAsSetsOfWholeValues() {
        let two = { (a: String, b: String) in [["attribute": a], ["attribute": b]] }
        let recording = Self.manifest(Self.metadataPolicy(uuid: "r", attributes: two(Self.campaign, Self.other)))
        #expect(Self.check(Self.manifest(Self.metadataPolicy(attributes: two(Self.other, Self.campaign))),
                           recording: recording) == nil)
        let repeated = [["attribute": Self.other], ["attribute": Self.campaign], ["attribute": Self.other]]
        #expect(Self.check(Self.manifest(Self.metadataPolicy(attributes: repeated)), recording: recording) == nil)
        let mismatches: [Any] = [
            [["attribute": Self.campaign]],
            [[String: String]](),
            two(Self.campaign, "https://patreon.arkavo.com/attr/campaign/value/7"),
            [["attribute": Self.campaign, "isDefault": true] as [String: Any], ["attribute": Self.other]],
            "x",
        ]
        for attributes in mismatches {
            #expect(Self.check(Self.manifest(Self.metadataPolicy(attributes: attributes)), recording: recording)
                == .policyMismatch, "\(attributes)")
        }
    }

    @Test func absentNullAndEmptyListsAreTheSame() {
        let empty = Self.manifest(["uuid": "r", "body": ["dataAttributes": [String](), "dissem": [String]()]])
        for body: Any in [["dataAttributes": NSNull()], [String: Any](), "not an object"] {
            #expect(Self.check(Self.manifest(["uuid": "m", "body": body]), recording: empty) == nil, "\(body)")
        }
        #expect(Self.check(Self.manifest(["uuid": "m", "body": [String: Any]()])) == .policyMismatch)
    }

    @Test func theDisseminationListMustMatch() {
        var policy = Self.metadataPolicy()
        policy["body"] = ["dataAttributes": [["attribute": Self.campaign]], "dissem": ["someone@example.com"]]
        #expect(Self.check(Self.manifest(policy)) == .policyMismatch)
    }

    @Test func theKASURLsMustMatchAsASet() {
        let recording = Self.manifest(Self.recordingPolicy(), kas: [Self.kas, "https://kas.example.com"])
        #expect(Self.check(Self.manifest(Self.metadataPolicy(), kas: ["https://kas.example.com", Self.kas]),
                           recording: recording) == nil)
        #expect(Self.check(Self.manifest(Self.metadataPolicy(), kas: [Self.kas]), recording: recording) == .policyMismatch)
        #expect(Self.check(Self.manifest(Self.metadataPolicy(), kas: ["https://other.example.com"])) == .policyMismatch)
    }

    @Test func metadataNeverReusesTheRecordingsPolicyID() {
        let id = "0b0e6f7c-0000-4000-8000-000000000001"
        #expect(Self.check(Self.manifest(Self.metadataPolicy(uuid: id))) == .reusesRecordingPolicyID)
    }

    @Test func unreadableManifestsAreRefused() {
        #expect(CatalogTDFManifest(manifestJSON: Data("{}".utf8)) == nil)
        #expect(CatalogTDFManifest(manifestJSON: Data(#"{"encryptionInformation":{"policy":"!!","keyAccess":[]}}"#.utf8))
            == nil)
        let notObject = Data("[1]".utf8).base64EncodedString()
        #expect(CatalogTDFManifest(manifestJSON: Data(#"{"encryptionInformation":{"policy":"\#(notObject)","keyAccess":[]}}"#.utf8)) == nil)
        let policy = Data(#"{"uuid":"u","body":{}}"#.utf8).base64EncodedString()
        #expect(CatalogTDFManifest(manifestJSON: Data(#"{"encryptionInformation":{"policy":"\#(policy)","keyAccess":[{"type":"wrapped"}]}}"#.utf8)) == nil)
        #expect(CatalogTDFManifest(manifestJSON: Data(#"{"encryptionInformation":{"policy":"\#(policy)","keyAccess":[]}}"#.utf8)) != nil)
    }

    @Test func aManifestPrintsNothingOfItsPolicy() {
        let manifest = Self.read(Self.manifest(Self.metadataPolicy()))
        #expect(String(describing: manifest) == "TDF manifest")
        #expect(String(reflecting: manifest) == "TDF manifest")
    }

    // MARK: The envelope

    static func envelope(attributes: Any = [["attribute": campaign]], uuid: Any = "envelope",
                         dissem: Any = [String](), extra: [String: Any] = [:],
                         mimeType: String? = CatalogEnvelope.mimeType, kas: [String] = [kas]) -> Data {
        var policy: [String: Any] = ["uuid": uuid, "body": ["dataAttributes": attributes, "dissem": dissem]]
        policy.merge(extra) { $1 }
        return manifest(policy, kas: kas, mimeType: mimeType)
    }

    static func checkEnvelope(_ data: Data, owner: String = "owner") -> CatalogEnvelopeRefusal? {
        do {
            try CatalogPublicationCheck.check(envelope: read(data), owner: owner)
            return nil
        } catch {
            return error
        }
    }

    @Test func anEnvelopeWithOneCampaignAttributeFits() {
        #expect(Self.checkEnvelope(Self.envelope()) == nil)
        let uuid = "0715eaff-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
        let creator = [["attribute": "https://arkavo.net/attr/creator/value/\(uuid)"]]
        #expect(Self.checkEnvelope(Self.envelope(attributes: creator), owner: uuid) == nil)
        #expect(Self.checkEnvelope(Self.envelope(attributes: [["attribute": "https://arkavo.net/attr/creator/value/arkavo:\(uuid)"]]),
                                   owner: "arkavo:\(uuid)") == .attribute)
        #expect(Self.checkEnvelope(Self.envelope(attributes: [["attribute": "https://patreon.arkavo.com/attr/campaign/value/a1"]]))
            == .attribute)
    }

    @Test func theEnvelopeMustHaveTheCatalogType() {
        for mimeType: String? in [CatalogEntryMetadata.mimeType, "application/json", "", nil] {
            #expect(Self.checkEnvelope(Self.envelope(mimeType: mimeType)) == .notACatalog, "\(String(describing: mimeType))")
        }
    }

    @Test func theEnvelopePolicyHasOnlyUUIDAndBody() {
        #expect(Self.checkEnvelope(Self.envelope(extra: ["arkavo:classification": "general"])) == .extraPolicyKeys)
        let noUUID = Self.manifest(["body": ["dataAttributes": [["attribute": Self.campaign]]]],
                                   mimeType: CatalogEnvelope.mimeType)
        #expect(Self.checkEnvelope(noUUID) == .extraPolicyKeys)
        for id: Any in ["", 7, NSNull()] {
            #expect(Self.checkEnvelope(Self.envelope(uuid: id)) == .noPolicyID, "\(id)")
        }
    }

    @Test func theEnvelopeHasExactlyOneAttributeOfItsOwner() {
        let refused: [Any] = [
            [[String: String]](),
            [["attribute": Self.campaign], ["attribute": Self.other]],
            [["attribute": Self.campaign], ["attribute": "https://arkavo.net/attr/creator/value/owner"]],
            [["attribute": "https://patreon.arkavo.com/attr/tier/value/1"]],
            [["attribute": "https://arkavo.net/attr/creator/value/someone-else"]],
            [["name": Self.campaign]],
            [Self.campaign],
            "x",
        ]
        for attributes in refused {
            #expect(Self.checkEnvelope(Self.envelope(attributes: attributes)) == .attribute, "\(attributes)")
        }
    }

    @Test func theEnvelopeIsDisseminatedToNoOne() {
        #expect(Self.checkEnvelope(Self.envelope(dissem: ["someone@example.com"])) == .dissemination)
        #expect(Self.checkEnvelope(Self.envelope(dissem: "x")) == .dissemination)
        #expect(Self.checkEnvelope(Self.envelope(dissem: NSNull())) == nil)
    }

    // MARK: A whole catalog

    /// A ZTDF archive holding `manifest` as `name`, and a payload.
    static func ztdf(_ manifest: Data, name: String = "manifest.json") -> Data {
        let archive = try! Archive(accessMode: .create)
        for (path, bytes) in [(name, manifest), ("0.payload", Data(repeating: 1, count: 32))] {
            try! archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { position, size in
                bytes.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return archive.data!
    }

    static func catalog(_ count: Int, metadataIDs: [String]? = nil,
                        metadata: [Int: Data] = [:]) -> CreatorCatalog {
        CreatorCatalog(owner: "owner", entries: (0..<count).map { index in
            CreatorCatalog.Entry(contentID: "rec-\(index)", version: 1, payloadHash: CreatorCatalogTests.hex(index),
                                 payloadSize: 1, metadata: metadata[index]
                                     ?? ztdf(manifest(metadataPolicy(uuid: metadataIDs?[index] ?? "metadata-\(index)"))))
        })
    }

    static func recordings(_ count: Int) -> [String: Data] {
        var recordings: [String: Data] = [:]
        for index in 0..<count {
            recordings[CreatorCatalogTests.hex(index)] = manifest(recordingPolicy(uuid: "recording-\(index)"),
                                                                  mimeType: "video/mp4")
        }
        return recordings
    }

    static func checkCatalog(_ catalog: CreatorCatalog, envelope: Data = envelope(),
                             recordings: [String: Data]? = nil) throws(CatalogPublicationError) {
        try CatalogPublicationCheck.check(catalog, envelope: envelope,
                                          recordings: recordings ?? Self.recordings(catalog.entries.count))
    }

    @Test func aCatalogWhoseTDFsFitPasses() {
        #expect(throws: Never.self) { try Self.checkCatalog(Self.catalog(3)) }
        #expect(throws: Never.self) { try Self.checkCatalog(Self.catalog(0)) }
    }

    @Test func theLegacyManifestNameIsRead() {
        let legacy = Self.ztdf(Self.manifest(Self.metadataPolicy(uuid: "m")), name: "0.manifest.json")
        #expect(throws: Never.self) { try Self.checkCatalog(Self.catalog(1, metadata: [0: legacy])) }
    }

    @Test func theEnvelopeIsCheckedFirst() {
        #expect(throws: CatalogPublicationError.unreadableEnvelope) {
            try Self.checkCatalog(Self.catalog(3), envelope: Data("{}".utf8))
        }
        #expect(throws: CatalogPublicationError.envelope(.notACatalog)) {
            try Self.checkCatalog(Self.catalog(3), envelope: Self.envelope(mimeType: "application/json"), recordings: [:])
        }
    }

    @Test func everyRecordingCarriesTheEnvelopeAttribute() {
        var recordings = Self.recordings(3)
        recordings[CreatorCatalogTests.hex(2)] = Self.manifest(
            ["uuid": "recording-2", "body": ["dataAttributes": [["attribute": Self.other]], "dissem": [String]()]],
            mimeType: "video/mp4")
        let otherMetadata = Self.ztdf(Self.manifest(Self.metadataPolicy(uuid: "metadata-2",
                                                                        attributes: [["attribute": Self.other]])))
        #expect(throws: CatalogPublicationError.lacksCatalogAttribute(2)) {
            try Self.checkCatalog(Self.catalog(3, metadata: [2: otherMetadata]), recordings: recordings)
        }
        let withExtraKey = [["attribute": Self.campaign, "displayName": "Campaign"]]
        recordings = Self.recordings(1)
        recordings[CreatorCatalogTests.hex(0)] = Self.manifest(
            ["uuid": "recording-0", "body": ["dataAttributes": withExtraKey, "dissem": [String]()]], mimeType: "video/mp4")
        let metadata = Self.ztdf(Self.manifest(Self.metadataPolicy(attributes: withExtraKey)))
        #expect(throws: Never.self) { try Self.checkCatalog(Self.catalog(1, metadata: [0: metadata]), recordings: recordings) }
    }

    @Test func theEnvelopesKASIsNotComparedWithTheRecordings() {
        #expect(throws: Never.self) {
            try Self.checkCatalog(Self.catalog(2), envelope: Self.envelope(kas: ["https://kas.example.com"]))
        }
    }

    @Test func aRepeatedMetadataPolicyIDNamesBothEntries() {
        #expect(throws: CatalogPublicationError.duplicatePolicyID(2, first: 0)) {
            try Self.checkCatalog(Self.catalog(3, metadataIDs: ["a", "b", "a"]))
        }
        #expect(throws: CatalogPublicationError.reusesEnvelopePolicyID(1)) {
            try Self.checkCatalog(Self.catalog(3, metadataIDs: ["a", "envelope", "c"]))
        }
    }

    @Test func aRefusalNamesItsEntry() {
        let untyped = Self.ztdf(Self.manifest(Self.metadataPolicy(), mimeType: "application/json"))
        #expect(throws: CatalogPublicationError.metadata(1, .notCatalogMetadata)) {
            try Self.checkCatalog(Self.catalog(3, metadata: [1: untyped]))
        }
    }

    @Test func missingAndUnreadableManifestsNameTheirEntry() {
        var recordings = Self.recordings(2)
        recordings[CreatorCatalogTests.hex(1)] = nil
        #expect(throws: CatalogPublicationError.missingManifest(1)) {
            try Self.checkCatalog(Self.catalog(2), recordings: recordings)
        }
        recordings = Self.recordings(2)
        recordings[CreatorCatalogTests.hex(1)] = Data("{}".utf8)
        #expect(throws: CatalogPublicationError.unreadableManifest(1)) {
            try Self.checkCatalog(Self.catalog(2), recordings: recordings)
        }
        // The metadata isn't a ZTDF, has no manifest, or its manifest is not one.
        for metadata in [Data("not a zip".utf8), Self.ztdf(Data("{}".utf8)), Self.ztdf(Self.manifest(Self.metadataPolicy()),
                                                                                     name: "other.json")] {
            #expect(throws: CatalogPublicationError.unreadableManifest(0)) {
                try Self.checkCatalog(Self.catalog(2, metadata: [0: metadata]))
            }
        }
    }
}
