import Foundation

/// The catalog envelope: one ZTDF whose payload is the `/2` document (`CreatorCatalog`). The node stores and serves its
/// bytes as the catalog document, and the signed pointer names them.
///
/// Its policy has only `uuid` (fresh) and `body`, with exactly one data attribute and no dissemination list, so anyone
/// who can play anything in the catalog can open the list:
/// - a creator with a Patreon campaign: `https://patreon.arkavo.com/attr/campaign/value/<campaign id>`;
/// - a creator without one: `https://arkavo.net/attr/creator/value/<sub>`, which only the creator holds.
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

    /// The attribute of a creator with a Patreon campaign.
    public static func campaignAttribute(campaignID: String) -> String {
        campaignAttributePrefix + campaignID
    }

    /// The attribute of a creator without a campaign.
    public static func creatorAttribute(subject: String) -> String {
        creatorAttributePrefix + subject
    }

    /// Whether `attribute` may be an envelope's for the catalog of `owner`: a campaign value (a non-empty id of
    /// `[A-Za-z0-9_-]`), or the creator value whose subject is `owner`, byte for byte.
    public static func isEnvelopeAttribute(_ attribute: String, owner: String) -> Bool {
        let bytes = Array(attribute.utf8)
        let campaign = Array(campaignAttributePrefix.utf8)
        if bytes.starts(with: campaign) {
            let id = bytes.dropFirst(campaign.count)
            return !id.isEmpty && id.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || byte == UInt8(ascii: "_")
                    || byte == UInt8(ascii: "-")
            }
        }
        return bytes == Array(creatorAttribute(subject: owner).utf8)
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
/// `{"bundle":{…},"document":"<base64url envelope>","index":[…]}`, at most 1 MiB.
public enum CatalogPublishRequest {
    public static let maxBytes = 1_048_576

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
