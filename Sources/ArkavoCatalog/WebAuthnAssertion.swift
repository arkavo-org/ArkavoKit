import CryptoKit
import Foundation

/// The WebAuthn assertion over a catalog pointer, checked against the credential key the IdP attested. These are the node's `verify_assertion` rules, in its order: the client data (`.clientDataType`, `.challenge`,
/// `.origin`, `.crossOrigin`), then the authenticator data (`.authenticatorData`, `.rpIDHash`, `.userPresence`,
/// `.userVerification`), then the signature (`.assertionSignature`). Nothing here reads a clock or logs a byte. Text is
/// compared as UTF-8 bytes, never with `String ==`.
public enum WebAuthnAssertion {
    public static let origin = "https://identity.arkavo.net"
    public static let relyingPartyIDHash = Data(SHA256.hash(data: Data("identity.arkavo.net".utf8)))

    private static let expectedType = "webauthn.get"
    /// `rpIdHash` (32), flags (1) and the counter (4); extension data may follow.
    private static let minimumAuthenticatorDataBytes = 37
    private static let flagsOffset = 32
    private static let userPresent: UInt8 = 0x01
    private static let userVerified: UInt8 = 0x04

    /// Verifies that `key` signed `pointer`, the exact bytes the node sent, as a WebAuthn assertion.
    ///
    /// `clientDataJSON` is one strict JSON object (`StrictJSON`: no byte-order mark, nothing after it, no repeated key); other
    /// members are ignored, and `crossOrigin` refuses only when it is `true`. The signature is DER. CryptoKit's DER parser
    /// is as strict as the node's `Signature::from_der` (it refuses trailing bytes, a long-form length, a padded integer and
    /// the raw 64-byte form), so the tests pin that it refuses them itself. The re-encode check below
    /// (`parsed.derRepresentation == signature`) is a hedge against a lenient future CryptoKit, and costs nothing today.
    /// CryptoKit hashes `authenticatorData ‖ SHA256(clientDataJSON)`, which is what the authenticator signed.
    public static func verify(pointer: Data, authenticatorData: Data, clientDataJSON: Data, signature: Data,
                              key: P256.Signing.PublicKey) throws {
        try checkClientData(clientDataJSON, pointer: pointer)
        try checkAuthenticatorData(authenticatorData)
        guard let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              parsed.derRepresentation == signature else {
            throw CatalogBundleError.assertionSignature
        }
        let signed = authenticatorData + Data(SHA256.hash(data: clientDataJSON))
        guard key.isValidSignature(parsed, for: signed) else { throw CatalogBundleError.assertionSignature }
    }

    private static func checkClientData(_ clientDataJSON: Data, pointer: Data) throws {
        guard let members = StrictJSON.parse(clientDataJSON)?.object, isText(members["type"], expectedType) else {
            throw CatalogBundleError.clientDataType
        }
        guard let challenge = members["challenge"]?.string, let decoded = Base64URL.decode(challenge),
              decoded == Data(SHA256.hash(data: pointer)) else {
            throw CatalogBundleError.challenge
        }
        guard isText(members["origin"], origin) else { throw CatalogBundleError.origin }
        if members["crossOrigin"] == .bool(true) { throw CatalogBundleError.crossOrigin }
    }

    private static func checkAuthenticatorData(_ data: Data) throws {
        guard data.count >= minimumAuthenticatorDataBytes else { throw CatalogBundleError.authenticatorData }
        let bytes = Array(data)
        guard Array(bytes[0..<flagsOffset]) == Array(relyingPartyIDHash) else { throw CatalogBundleError.rpIDHash }
        let flags = bytes[flagsOffset]
        guard flags & userPresent != 0 else { throw CatalogBundleError.userPresence }
        guard flags & userVerified != 0 else { throw CatalogBundleError.userVerification }
    }

    private static func isText(_ value: StrictJSON?, _ expected: String) -> Bool {
        guard let text = value?.string else { return false }
        return Array(text.utf8) == Array(expected.utf8)
    }
}
