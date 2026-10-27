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

/// Why a `/2` catalog would be refused at publish. Each case names the entry by its position in `entries`.
public enum CatalogPublicationError: Error, Sendable, Equatable {
    /// No manifest was given for the entry's recording or metadata TDF.
    case missingManifest(Int)
    /// A manifest given for the entry is not a readable ZTDF manifest.
    case unreadableManifest(Int)
    case metadata(Int, CatalogMetadataRefusal)
    /// The entry's metadata policy `uuid` is also the one of the entry at `first`. The viewer unwraps all of a catalog's
    /// metadata in one bulk rewrap, and the KAS refuses repeated policy ids (the node's check 8e).
    case duplicatePolicyID(Int, first: Int)
}

/// The node's publish checks on a `/2` catalog's TDFs, run before publishing so a catalog the node would refuse with a
/// 422 is never sent. The document's own rules are `CreatorCatalog.encoded()`'s.
public enum CatalogPublicationCheck {
    /// Checks every entry in order, each against its recording, then its policy `uuid` against the entries before it.
    /// `manifests` maps each `payloadHash` and `metadataHash` to that TDF's `manifest.json` bytes.
    public static func check(_ catalog: CreatorCatalog,
                             manifests: [String: Data]) throws(CatalogPublicationError) {
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
            policyIDs[id] = index
        }
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
