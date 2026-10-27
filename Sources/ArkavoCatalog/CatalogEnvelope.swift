import Foundation

/// The catalog envelope: one ZTDF whose payload is the `/2` document (`CreatorCatalog`). The node stores and serves its
/// bytes as the catalog document, and the signed pointer names them.
///
/// Its policy has only `uuid` (fresh) and `body`, with exactly one data attribute and no dissemination list, so anyone
/// who can play anything in the catalog can open the list:
/// - a creator with a Patreon campaign: `https://patreon.arkavo.com/attr/campaign/value/<campaign id>`, the numeric id
///   the platform grants patrons;
/// - a creator without one: `https://arkavo.net/attr/creator/value/<account UUID>`, which only the creator holds.
///   Identity mints it with the bare lowercase account UUID (the passkey CWT's `sub`, `arkavo_account_id` on every
///   token), never `arkavo:<uuid>`, so the catalog's owner must be that UUID.
///
/// Never both, since the platform ANDs across attribute definitions. That attribute must be in every entry's recording
/// policy (`CatalogPublicationCheck`). Wrapping and unwrapping the envelope are the caller's, with OpenTDFKit.
public enum CatalogEnvelope {
    /// The envelope manifest's `payload.mimeType`.
    public static let mimeType = "application/vnd.arkavo.creator-catalog+json"
    /// The envelope's size, which the pointer's `catalogSize` names.
    public static let maxBytes = CreatorCatalog.maxDocumentBytes
    public static let campaignAttributePrefix = "https://patreon.arkavo.com/attr/campaign/value/"
    public static let creatorAttributePrefix = "https://arkavo.net/attr/creator/value/"

    /// The attribute of a creator with a Patreon campaign. `isEnvelopeAttribute` requires a numeric id.
    public static func campaignAttribute(campaignID: String) -> String {
        campaignAttributePrefix + campaignID
    }

    /// The attribute of a creator without a campaign. `subject` is the bare lowercase account UUID, never
    /// `arkavo:<uuid>`; `isEnvelopeAttribute` refuses anything else.
    public static func creatorAttribute(subject: String) -> String {
        creatorAttributePrefix + subject
    }

    /// Whether `attribute` may be an envelope's for the catalog of `owner`, as the platform grants them: a campaign value
    /// with a numeric id (the platform's Patreon source grants only `^[0-9]+$`), or the creator value of `owner`, byte for
    /// byte, when `owner` is a bare lowercase account UUID. A value the platform never grants would lock everyone out.
    public static func isEnvelopeAttribute(_ attribute: String, owner: String) -> Bool {
        let bytes = Array(attribute.utf8)
        let campaign = Array(campaignAttributePrefix.utf8)
        if bytes.starts(with: campaign) {
            let id = bytes.dropFirst(campaign.count)
            return !id.isEmpty && id.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        }
        return isAccountUUID(owner) && bytes == Array(creatorAttribute(subject: owner).utf8)
    }

    /// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` in lowercase hex, as identity writes an account id.
    static func isAccountUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            [8, 13, 18, 23].contains(index) ? byte == UInt8(ascii: "-")
                : (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    /// Checks fetched envelope bytes against the verified pointer that names them, in this order: the size limit
    /// (`.tooLarge`), the pointer's `catalogSize` (`.sizeMismatch`), then its `catalogHash` with the caller's BLAKE3, as
    /// 64 lowercase hex (`.hashMismatch`). Unwrap the envelope next, then decode its payload with
    /// `CreatorCatalog.decode(_:owner:)` and the pointer's owner.
    public static func verify(_ envelope: Data, pointer: CatalogPointer,
                              blake3: (Data) -> String) throws(CatalogDocumentError) {
        guard envelope.count <= maxBytes else { throw .tooLarge }
        guard envelope.count == pointer.catalogSize else { throw .sizeMismatch }
        guard blake3(envelope).utf8.elementsEqual(pointer.catalogHash.utf8) else { throw .hashMismatch }
    }
}

/// Why a publish request can't be built.
public enum CatalogPublishRequestError: Error, Sendable, Equatable {
    /// The envelope is empty or larger than `CatalogEnvelope.maxBytes`.
    case envelopeSize
    /// The bundle's pointer does not name the envelope's size or BLAKE3 hash, or another owner.
    case pointerMismatch
    case index(CreatorCatalogError)
    /// The body is larger than `CatalogPublishRequest.maxBytes`.
    case tooLarge
}

/// The body of `PUT /v2/catalogs/{sub}`, the only route that publishes `/2`:
/// `{"bundle":{…},"document":"<base64url envelope>","index":[…]}`, at most 10 MiB, the node's limit. The largest envelope
/// is about 5.6 MB in base64url and the largest index about 0.5 MB, so any valid catalog fits.
public enum CatalogPublishRequest {
    public static let maxBytes = 10_485_760

    /// The body for `envelope`, signed by `bundle`, listing `catalog` (the envelope's payload) in the clear as `index`.
    /// The pointer must name the envelope's size and hash (with the caller's BLAKE3) and the catalog's owner. The node
    /// can't compare `index` with the encrypted payload, so `catalog` must be exactly what the envelope holds.
    public static func body(envelope: Data, bundle: CatalogBundle, catalog: CreatorCatalog,
                            blake3: (Data) -> String) throws(CatalogPublishRequestError) -> Data {
        guard (1...CatalogEnvelope.maxBytes).contains(envelope.count) else { throw .envelopeSize }
        guard let pointer = try? CatalogPointer.decode(bundle.pointer), pointer.catalogSize == envelope.count,
              blake3(envelope).utf8.elementsEqual(pointer.catalogHash.utf8),
              pointer.owner.utf8.elementsEqual(catalog.owner.utf8) else { throw .pointerMismatch }
        let index: Data
        do {
            index = try catalog.encodedIndex()
        } catch {
            throw .index(error)
        }
        var body = Data(#"{"bundle":"#.utf8)
        body.append(bundle.encoded())
        body.append(Data(#","document":""#.utf8))
        body.append(Data(Base64URL.encode(envelope).utf8))
        body.append(Data(#"","index":"#.utf8))
        body.append(index)
        body.append(Data("}".utf8))
        guard body.count <= maxBytes else { throw .tooLarge }
        return body
    }
}
