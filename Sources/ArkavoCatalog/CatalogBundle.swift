import Foundation

/// Why a catalog bundle was refused. It carries no bytes; `rollback` carries only the highest `seq` already seen. The
/// cases follow the verification order.
public enum CatalogBundleError: Error, Sendable, Equatable {
    case malformed, pointer, pointerOwner
    case attestationEnvelope, unknownKey, attestationSignature, attestationClaims, attestationFromFuture
    case attestationSubject, credentialID
    case clientDataType, challenge, origin, crossOrigin
    case authenticatorData, rpIDHash, userPresence, userVerification, assertionSignature
    case rollback(highestSeen: UInt64)
}

/// A signed catalog pointer as the node stores and serves it:
/// `{"pointer","assertion":{"credentialId","authenticatorData","clientDataJSON","signature"},"credential"}`. Each
/// object has exactly those keys (the node refuses unknown fields, so there is no `userHandle`), and every value is a
/// string except `assertion`. Every binary value is canonical unpadded base64url (`Base64URL`) of a bounded size.
///
/// This type only encodes and decodes; `CatalogBundleVerifier` verifies. It holds signatures and the attestation, so it
/// prints and reflects as a fixed text.
public struct CatalogBundle: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public static let maxBytes = 32_768
    private static let topKeys: Set<String> = ["pointer", "assertion", "credential"]
    private static let assertionKeys: Set<String> = ["credentialId", "authenticatorData", "clientDataJSON", "signature"]
    private static let pointerSizes = 1...CatalogPointer.maxBytes
    private static let credentialIDSizes = 1...1_023
    private static let authenticatorDataSizes = 1...4_096
    private static let clientDataJSONSizes = 1...4_096
    private static let signatureSizes = 1...80
    private static let attestationSizes = 1...4_096

    /// The signed pointer bytes, exactly as signed.
    public let pointer: Data
    public let credentialID: Data
    public let authenticatorData: Data
    public let clientDataJSON: Data
    /// ASN.1 DER ECDSA.
    public let signature: Data
    /// identity.arkavo.net's COSE_Sign1 credential attestation, sent as `credential`.
    public let attestation: Data

    /// Throws `CatalogBundleError.malformed` when a value is outside the sizes `decode` accepts.
    public init(pointer: Data, credentialID: Data, authenticatorData: Data, clientDataJSON: Data, signature: Data,
                attestation: Data) throws(CatalogBundleError) {
        guard Self.pointerSizes.contains(pointer.count), Self.credentialIDSizes.contains(credentialID.count),
              Self.authenticatorDataSizes.contains(authenticatorData.count),
              Self.clientDataJSONSizes.contains(clientDataJSON.count), Self.signatureSizes.contains(signature.count),
              Self.attestationSizes.contains(attestation.count) else { throw .malformed }
        self.pointer = pointer
        self.credentialID = credentialID
        self.authenticatorData = authenticatorData
        self.clientDataJSON = clientDataJSON
        self.signature = signature
        self.attestation = attestation
    }

    public var description: String { "Catalog bundle" }
    public var debugDescription: String { "Catalog bundle" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    /// The bundle's JSON, sorted keys.
    public func encoded() -> Data {
        let wire = Wire(pointer: Base64URL.encode(pointer),
                        assertion: .init(credentialId: Base64URL.encode(credentialID),
                                         authenticatorData: Base64URL.encode(authenticatorData),
                                         clientDataJSON: Base64URL.encode(clientDataJSON),
                                         signature: Base64URL.encode(signature)),
                        credential: Base64URL.encode(attestation))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Strings of the base64url alphabet always encode.
        return (try? encoder.encode(wire)) ?? Data()
    }

    /// Throws `CatalogBundleError.malformed` for anything that is not a bundle. Nothing is verified.
    public static func decode(_ json: Data) throws(CatalogBundleError) -> CatalogBundle {
        guard json.count <= maxBytes, let root = StrictJSON.parse(json)?.object, Set(root.keys) == topKeys,
              let assertion = root["assertion"]?.object, Set(assertion.keys) == assertionKeys,
              let pointer = binary(root["pointer"]), let credentialID = binary(assertion["credentialId"]),
              let authenticatorData = binary(assertion["authenticatorData"]),
              let clientDataJSON = binary(assertion["clientDataJSON"]), let signature = binary(assertion["signature"]),
              let attestation = binary(root["credential"]) else {
            throw .malformed
        }
        return try CatalogBundle(pointer: pointer, credentialID: credentialID, authenticatorData: authenticatorData,
                                 clientDataJSON: clientDataJSON, signature: signature, attestation: attestation)
    }

    private static func binary(_ value: StrictJSON?) -> Data? {
        guard let text = value?.string else { return nil }
        return Base64URL.decode(text)
    }

    private struct Wire: Encodable {
        struct Assertion: Encodable {
            let credentialId: String
            let authenticatorData: String
            let clientDataJSON: String
            let signature: String
        }

        let pointer: String
        let assertion: Assertion
        let credential: String
    }
}
