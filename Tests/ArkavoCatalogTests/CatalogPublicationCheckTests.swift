import Foundation
import Testing
@testable import ArkavoCatalog

/// The node's publish checks 8b–8e, mirrored from tdf-iroh-s3's `catalog_metadata.rs` tests, plus Creator's own rule that a
/// metadata TDF never reuses its recording's policy uuid.
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

    // MARK: A whole catalog

    static func catalog(_ count: Int) -> CreatorCatalog {
        CreatorCatalog(owner: "owner", entries: (0..<count).map { index in
            CreatorCatalog.Entry(contentID: "rec-\(index)", version: 1, payloadHash: CreatorCatalogTests.hex(index),
                                 payloadSize: 1, metadataHash: CreatorCatalogTests.hex(index + 100), metadataSize: 1)
        })
    }

    static func manifests(_ count: Int, metadataIDs: [String]? = nil) -> [String: Data] {
        var manifests: [String: Data] = [:]
        for index in 0..<count {
            manifests[CreatorCatalogTests.hex(index)] = manifest(recordingPolicy(uuid: "recording-\(index)"),
                                                                 mimeType: "video/mp4")
            manifests[CreatorCatalogTests.hex(index + 100)] = manifest(metadataPolicy(uuid: metadataIDs?[index]
                    ?? "metadata-\(index)"))
        }
        return manifests
    }

    @Test func aCatalogWhoseTDFsFitPasses() {
        #expect(throws: Never.self) { try CatalogPublicationCheck.check(Self.catalog(3), manifests: Self.manifests(3)) }
    }

    @Test func aRepeatedMetadataPolicyIDNamesBothEntries() {
        #expect(throws: CatalogPublicationError.duplicatePolicyID(2, first: 0)) {
            try CatalogPublicationCheck.check(Self.catalog(3), manifests: Self.manifests(3, metadataIDs: ["a", "b", "a"]))
        }
    }

    @Test func aRefusalNamesItsEntry() {
        var manifests = Self.manifests(3)
        manifests[CreatorCatalogTests.hex(101)] = Self.manifest(Self.metadataPolicy(), mimeType: "application/json")
        #expect(throws: CatalogPublicationError.metadata(1, .notCatalogMetadata)) {
            try CatalogPublicationCheck.check(Self.catalog(3), manifests: manifests)
        }
    }

    @Test func missingAndUnreadableManifestsNameTheirEntry() {
        var manifests = Self.manifests(2)
        manifests[CreatorCatalogTests.hex(1)] = nil
        #expect(throws: CatalogPublicationError.missingManifest(1)) {
            try CatalogPublicationCheck.check(Self.catalog(2), manifests: manifests)
        }
        manifests = Self.manifests(2)
        manifests[CreatorCatalogTests.hex(100)] = Data("{}".utf8)
        #expect(throws: CatalogPublicationError.unreadableManifest(0)) {
            try CatalogPublicationCheck.check(Self.catalog(2), manifests: manifests)
        }
    }
}
