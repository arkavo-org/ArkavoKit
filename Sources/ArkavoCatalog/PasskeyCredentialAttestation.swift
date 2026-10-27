import CryptoKit
import Foundation

/// identity.arkavo.net's COSE_Sign1 credential attestation, split but not yet verified. The
/// envelope is checked; the payload is not read until its signature verifies. It holds the IdP's signature, so it prints and
/// reflects as a fixed text.
public struct CredentialAttestationEnvelope: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// The protected header's `kid`: non-empty and opaque, compared as bytes.
    public let keyID: Data
    /// The protected header and the payload exactly as received; the signature covers these bytes.
    let protected: Data, payload: Data
    let signature: P256.Signing.ECDSASignature

    /// Only `PasskeyCredentialAttestation.envelope` makes one, so `keyID` always comes from the `protected` bytes beside it.
    fileprivate init(keyID: Data, protected: Data, payload: Data, signature: P256.Signing.ECDSASignature) {
        self.keyID = keyID
        self.protected = protected
        self.payload = payload
        self.signature = signature
    }

    public var description: String { "Credential attestation" }
    public var debugDescription: String { "Credential attestation" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The passkey credential the IdP attested: `subject`'s credential `credentialID` had `publicKey` at `issuedAt`.
public struct PasskeyCredential: Sendable {
    public let subject: String
    public let credentialID: Data
    public let publicKey: P256.Signing.PublicKey
    public let issuedAt: Int64
}

/// The reader's rules for authnz-rs `credential_attestation.rs`. `envelope` refuses anything
/// that is not one with `.attestationEnvelope`. `verify` checks the signature (`.attestationSignature`), then the claims
/// (`.attestationClaims`), then the clock (`.attestationFromFuture`). Looking up the key for `keyID`, and binding the subject
/// and credential id to the bundle, are the caller's. Text is compared as UTF-8 bytes, never with `String ==`.
public enum PasskeyCredentialAttestation {
    public static let contentType = "application/arkavo-passkey-credential+cbor"
    public static let typ = "arkavo-passkey-credential"
    public static let issuer = "https://identity.arkavo.net"
    public static let relyingPartyID = "identity.arkavo.net"
    /// How far `iat` may lie after the device's clock, in seconds. There is no lower bound and no expiry.
    public static let maxClockSkew: Int64 = 60

    private static let claimNames = ["typ", "iss", "sub", "credentialId", "publicKey", "rpId", "iat"]

    /// COSE_Sign1 tagged 18 or untagged, with nothing after it: `[protected bstr, unprotected map, payload bstr,
    /// signature bstr of 64]`. The protected header is one map with no repeated label: alg ES256 (−7), the content type,
    /// a non-empty byte-string kid and no crit. Other int and text labels, and the unprotected map's contents, are ignored.
    public static func envelope(_ bytes: Data) throws -> CredentialAttestationEnvelope {
        var reader = CBORReader(bytes: Array(bytes))
        guard var item = try? reader.read(), reader.isAtEnd else { throw CatalogBundleError.attestationEnvelope }
        if case .tag(18, let tagged) = item { item = tagged }
        guard case .array(let items) = item, items.count == 4,
              case .bytes(let protected) = items[0], case .map = items[1], case .bytes(let payload) = items[2],
              case .bytes(let signature) = items[3], signature.count == 64,
              let keyID = keyID(protectedHeader: protected),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
            throw CatalogBundleError.attestationEnvelope
        }
        return CredentialAttestationEnvelope(keyID: Data(keyID), protected: Data(protected), payload: Data(payload),
                                             signature: signature)
    }

    /// The attested credential, when `key` signed the envelope, its payload is a passkey credential, and its `iat` is at
    /// most `maxClockSkew` seconds after `now` (whole seconds since 1970).
    ///
    /// Attestation bytes are not unique: high-S signatures (authnz-rs's golden vector is one) and non-minimal heads at any
    /// level are accepted, so never dedupe or cache by attestation bytes.
    public static func verify(_ envelope: CredentialAttestationEnvelope, key: P256.Signing.PublicKey,
                              now: Int64) throws -> PasskeyCredential {
        let signed = sigStructure(protected: envelope.protected, payload: envelope.payload)
        guard key.isValidSignature(envelope.signature, for: signed) else { throw CatalogBundleError.attestationSignature }
        guard let credential = credential(payload: Array(envelope.payload)) else {
            throw CatalogBundleError.attestationClaims
        }
        // iat is 0…Int64.max, so iat − 60 cannot overflow where now + 60 could.
        guard credential.issuedAt - maxClockSkew <= now else { throw CatalogBundleError.attestationFromFuture }
        return credential
    }

    /// `Sig_structure` for COSE_Sign1 with empty external data: `["Signature1", protected, h'', payload]`, the byte strings
    /// exactly as given, with shortest-form heads.
    static func sigStructure(protected: Data, payload: Data) -> Data {
        var structure = Data([0x84, 0x6A])
        structure.append(contentsOf: Array("Signature1".utf8))
        appendByteString(protected, to: &structure)
        structure.append(0x40)
        appendByteString(payload, to: &structure)
        return structure
    }

    private static func appendByteString(_ bytes: Data, to data: inout Data) {
        let count = UInt64(bytes.count)
        let width = count < 24 ? 0 : count <= 0xFF ? 1 : count <= 0xFFFF ? 2 : count <= 0xFFFF_FFFF ? 4 : 8
        let info: UInt8 = switch width {
        case 0: UInt8(count)
        case 1: 24
        case 2: 25
        case 4: 26
        default: 27
        }
        data.append(0x40 | info)
        for index in stride(from: width - 1, through: 0, by: -1) {
            data.append(UInt8(truncatingIfNeeded: count >> UInt64(index * 8)))
        }
        data.append(contentsOf: bytes)
    }

    // MARK: The protected header

    /// A COSE header or key label: an integer or a text string (RFC 9052). Text labels are told apart by their UTF-8 bytes.
    /// The identity key set's entries use it too.
    enum Label: Hashable {
        case uint(UInt64), nint(UInt64), text([UInt8])
    }

    static func label(_ item: CBOR) -> Label? {
        switch item {
        case .uint(let value): .uint(value)
        case .nint(let value): .nint(value)
        case .text(let text): .text(Array(text.utf8))
        default: nil
        }
    }

    /// The kid of a protected header that passes the envelope's rules, or nil.
    private static func keyID(protectedHeader bytes: [UInt8]) -> [UInt8]? {
        var reader = CBORReader(bytes: bytes)
        guard let item = try? reader.read(), reader.isAtEnd, case .map(let pairs) = item else { return nil }
        var seen = Set<Label>()
        var alg: CBOR?, contentType: CBOR?, kid: CBOR?
        for (key, value) in pairs {
            guard let label = label(key), seen.insert(label).inserted else { return nil }
            switch label {
            case .uint(1): alg = value
            case .uint(2): return nil // crit: the reader understands no extension.
            case .uint(3): contentType = value
            case .uint(4): kid = value
            default: continue
            }
        }
        guard case .nint(6)? = alg, case .text(let type)? = contentType, isText(type, self.contentType),
              case .bytes(let kid)? = kid, !kid.isEmpty else { return nil }
        return kid
    }

    // MARK: The payload

    /// The payload as a credential: a map of exactly the seven text claims, each once, with nothing after it.
    private static func credential(payload: [UInt8]) -> PasskeyCredential? {
        var reader = CBORReader(bytes: payload)
        guard let item = try? reader.read(), reader.isAtEnd, case .map(let pairs) = item,
              pairs.count == claimNames.count else { return nil }
        var claims: [String: CBOR] = [:]
        for (key, value) in pairs {
            guard case .text(let text) = key, let name = claimNames.first(where: { isText(text, $0) }),
                  claims.updateValue(value, forKey: name) == nil else { return nil }
        }
        guard case .text(let typ)? = claims["typ"], isText(typ, self.typ),
              case .text(let issuer)? = claims["iss"], isText(issuer, self.issuer),
              case .text(let subject)? = claims["sub"], !subject.utf8.isEmpty,
              case .bytes(let credentialID)? = claims["credentialId"], !credentialID.isEmpty,
              let publicKey = publicKey(claims["publicKey"]),
              case .text(let relyingPartyID)? = claims["rpId"], isText(relyingPartyID, self.relyingPartyID),
              case .uint(let issuedAt)? = claims["iat"], issuedAt <= UInt64(Int64.max) else { return nil }
        return PasskeyCredential(subject: subject, credentialID: Data(credentialID), publicKey: publicKey,
                                 issuedAt: Int64(issuedAt))
    }

    /// An EC2 P-256 COSE_Key: kty (1) = EC2 (2), crv (−1) = P-256 (1), x (−2) and y (−3) of 32 bytes, each once, on the
    /// curve. Other labels are ignored. The identity key set's entries use it too.
    static func publicKey(_ item: CBOR?) -> P256.Signing.PublicKey? {
        guard case .map(let pairs)? = item else { return nil }
        var kty: CBOR?, crv: CBOR?, x: CBOR?, y: CBOR?
        for (label, value) in pairs {
            switch label {
            case .uint(1):
                guard kty == nil else { return nil }
                kty = value
            case .nint(0):
                guard crv == nil else { return nil }
                crv = value
            case .nint(1):
                guard x == nil else { return nil }
                x = value
            case .nint(2):
                guard y == nil else { return nil }
                y = value
            default: continue
            }
        }
        guard case .uint(2)? = kty, case .uint(1)? = crv, case .bytes(let x)? = x, x.count == 32,
              case .bytes(let y)? = y, y.count == 32 else { return nil }
        // CryptoKit refuses a point that is not on the curve.
        return try? P256.Signing.PublicKey(x963Representation: [0x04] + x + y)
    }

    /// Whether `text` is exactly `expected`, byte for byte (`String ==` would accept canonically equivalent text).
    private static func isText(_ text: String, _ expected: String) -> Bool {
        text.utf8.elementsEqual(expected.utf8)
    }
}
