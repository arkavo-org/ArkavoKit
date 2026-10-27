import Foundation

/// The parts of a ZTDF `manifest.json` the publication checks read: `payload.mimeType`, the policy decoded from
/// `encryptionInformation.policy` (standard base64 of a JSON object), and the `url` of each
/// `encryptionInformation.keyAccess` object. Reading it needs no key: every manifest is readable by anyone holding the
/// TDF's hash. It prints and reflects as a fixed text, so no policy value reaches a log.
public struct CatalogTDFManifest: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public let mimeType: String?
    /// The policy's `uuid` when it is a non-empty string.
    public var policyID: String? {
        guard let id = policy["uuid"]?.string, !id.isEmpty else { return nil }
        return id
    }
    public let kasURLs: Set<String>
    let policy: [String: StrictJSON]

    /// Nil unless `manifestJSON` is one strict JSON object with a base64 JSON-object policy and a `keyAccess` array whose
    /// objects all have a string `url`.
    public init?(manifestJSON: Data) {
        guard let manifest = StrictJSON.parse(manifestJSON)?.object,
              let information = manifest["encryptionInformation"]?.object,
              let encoded = information["policy"]?.string, let decoded = Data(base64Encoded: encoded),
              let policy = StrictJSON.parse(decoded)?.object,
              let keyAccess = information["keyAccess"]?.array else { return nil }
        var kasURLs = Set<String>()
        for object in keyAccess {
            guard let url = object.object?["url"]?.string else { return nil }
            kasURLs.insert(url)
        }
        self.mimeType = manifest["payload"]?.object?["mimeType"]?.string
        self.policy = policy
        self.kasURLs = kasURLs
    }

    public var description: String { "TDF manifest" }
    public var debugDescription: String { "TDF manifest" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    /// `body.<key>` as a list, as the node reads it: absent, `null` or a `body` that is not an object give an empty list;
    /// any other value that is not an array gives nil, which matches nothing.
    func list(_ key: String) -> [StrictJSON]? {
        guard let body = policy["body"]?.object else { return [] }
        switch body[key] {
        case nil, .null?: return []
        case .array(let items)?: return items
        default: return nil
        }
    }
}

/// Why a metadata TDF may not stand for its recording in a catalog. The first four are the node's publish checks 8b–8d;
/// `reusesRecordingPolicyID` is Creator's own.
public enum CatalogMetadataRefusal: Error, Sendable, Equatable {
    /// The policy has a top-level key besides `uuid` and `body`, or lacks one of them.
    case extraPolicyKeys
    /// The policy's `uuid` is not a non-empty string.
    case noPolicyID
    /// `payload.mimeType` is not `CatalogEntryMetadata.mimeType`.
    case notCatalogMetadata
    /// The attributes, dissemination list or KAS URLs differ from the recording's.
    case policyMismatch
    /// The policy `uuid` is the recording's.
    case reusesRecordingPolicyID
}

/// Why an envelope may not carry a catalog. The node refuses the first three (its checks 2 and 3 for `/2` on
/// `PUT /v2/catalogs`); the last two are the design's and Creator's own.
public enum CatalogEnvelopeRefusal: Error, Sendable, Equatable {
    /// `payload.mimeType` is not `CatalogEnvelope.mimeType`.
    case notACatalog
    /// The policy has a top-level key besides `uuid` and `body`, or lacks one of them.
    case extraPolicyKeys
    /// `body.dataAttributes` is not exactly one attribute that `CatalogEnvelope.isEnvelopeAttribute` accepts for the
    /// catalog's owner.
    case attribute
    /// The policy's `uuid` is not a non-empty string.
    case noPolicyID
    /// `body.dissem` is not empty.
    case dissemination
}

/// Why a `/2` catalog would be refused at publish. Each entry case names the entry by its position in `entries`.
public enum CatalogPublicationError: Error, Sendable, Equatable {
    /// The envelope's manifest is not a readable ZTDF manifest.
    case unreadableEnvelope
    case envelope(CatalogEnvelopeRefusal)
    /// No manifest was given for the entry's recording or metadata TDF.
    case missingManifest(Int)
    /// A manifest given for the entry is not a readable ZTDF manifest.
    case unreadableManifest(Int)
    case metadata(Int, CatalogMetadataRefusal)
    /// The entry's metadata policy `uuid` is also the one of the entry at `first`. The viewer unwraps all of a catalog's
    /// metadata in one bulk rewrap, and the KAS refuses repeated policy ids (the node's check 8e).
    case duplicatePolicyID(Int, first: Int)
    /// The entry's metadata policy `uuid` is the envelope's.
    case reusesEnvelopePolicyID(Int)
    /// The entry's recording policy lacks the envelope's attribute, so someone who can open the entry couldn't open the
    /// catalog that lists it.
    case lacksCatalogAttribute(Int)
}

/// The node's publish checks on a `/2` catalog's TDFs, run before publishing so a catalog the node would refuse with a
/// 422 is never sent. The document's and the index's own rules are `CreatorCatalog.encoded()`'s.
public enum CatalogPublicationCheck {
    /// Checks the envelope, then every entry in order: its metadata against its recording, its metadata policy `uuid`
    /// against the envelope's and the entries' before it, then that its recording carries the envelope's attribute.
    /// `envelope` is the envelope's `manifest.json` bytes; `manifests` maps each `payloadHash` and `metadataHash` to that
    /// TDF's.
    public static func check(_ catalog: CreatorCatalog, envelope: Data,
                             manifests: [String: Data]) throws(CatalogPublicationError) {
        guard let envelope = CatalogTDFManifest(manifestJSON: envelope) else { throw .unreadableEnvelope }
        let attribute: String
        do {
            attribute = try check(envelope: envelope, owner: catalog.owner)
        } catch {
            throw .envelope(error)
        }
        var policyIDs: [String: Int] = [:]
        for (index, entry) in catalog.entries.enumerated() {
            guard let recordingJSON = manifests[entry.payloadHash], let metadataJSON = manifests[entry.metadataHash]
            else { throw .missingManifest(index) }
            guard let recording = CatalogTDFManifest(manifestJSON: recordingJSON),
                  let metadata = CatalogTDFManifest(manifestJSON: metadataJSON) else { throw .unreadableManifest(index) }
            do {
                try check(metadata: metadata, recording: recording)
            } catch {
                throw .metadata(index, error)
            }
            // check(metadata:recording:) passed, so the policy id is a non-empty string.
            guard let id = metadata.policyID else { throw .metadata(index, .noPolicyID) }
            if let first = policyIDs[id] { throw .duplicatePolicyID(index, first: first) }
            if id.utf8.elementsEqual((envelope.policyID ?? "").utf8) { throw .reusesEnvelopePolicyID(index) }
            policyIDs[id] = index
            guard recording.list("dataAttributes")?.contains(where: {
                $0.object?["attribute"]?.string?.utf8.elementsEqual(attribute.utf8) == true
            }) == true else { throw .lacksCatalogAttribute(index) }
        }
    }

    /// Whether `envelope` may carry the catalog of `owner`, in the node's order: the mime type, the policy's keys, then
    /// its one attribute; then the design's: the `uuid`, and an empty dissemination list. Returns the attribute, which
    /// every recording's `dataAttributes` must carry.
    @discardableResult
    static func check(envelope: CatalogTDFManifest, owner: String) throws(CatalogEnvelopeRefusal) -> String {
        guard let mimeType = envelope.mimeType, mimeType.utf8.elementsEqual(CatalogEnvelope.mimeType.utf8) else {
            throw .notACatalog
        }
        guard Set(envelope.policy.keys) == ["uuid", "body"] else { throw .extraPolicyKeys }
        guard let attributes = envelope.list("dataAttributes"), attributes.count == 1,
              let fqn = attributes[0].object?["attribute"]?.string,
              CatalogEnvelope.isEnvelopeAttribute(fqn, owner: owner) else { throw .attribute }
        guard envelope.policyID != nil else { throw .noPolicyID }
        guard envelope.list("dissem")?.isEmpty == true else { throw .dissemination }
        return fqn
    }

    /// Whether `metadata` may stand for `recording`, in the node's order: the policy's keys, its `uuid`, the mime type,
    /// then the attributes (`body.dataAttributes`), dissemination list (`body.dissem`) and KAS URLs, each compared as a
    /// set of whole JSON values. Last, the metadata's `uuid` must not be the recording's.
    public static func check(metadata: CatalogTDFManifest,
                             recording: CatalogTDFManifest) throws(CatalogMetadataRefusal) {
        guard Set(metadata.policy.keys) == ["uuid", "body"] else { throw .extraPolicyKeys }
        guard let id = metadata.policyID else { throw .noPolicyID }
        guard let mimeType = metadata.mimeType, mimeType.utf8.elementsEqual(CatalogEntryMetadata.mimeType.utf8) else {
            throw .notCatalogMetadata
        }
        guard metadata.kasURLs == recording.kasURLs,
              sameSet(metadata.list("dataAttributes"), recording.list("dataAttributes")),
              sameSet(metadata.list("dissem"), recording.list("dissem")) else { throw .policyMismatch }
        if let recordingID = recording.policyID, recordingID.utf8.elementsEqual(id.utf8) {
            throw .reusesRecordingPolicyID
        }
    }

    /// Equal as sets: order and repeats ignored. Numbers compare as their text, so `1` and `1.0` differ.
    private static func sameSet(_ lhs: [StrictJSON]?, _ rhs: [StrictJSON]?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.allSatisfy(rhs.contains) && rhs.allSatisfy(lhs.contains)
    }
}
