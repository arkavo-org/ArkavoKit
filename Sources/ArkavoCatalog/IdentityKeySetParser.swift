import CryptoKit
import Foundation

public protocol IdentityKeyLookup: Sendable {
    /// The key identity.arkavo.net lists for `keyID`, from a set the caller fetched (`IdentityKeySetParser`) and keeps
    /// fresh; nil when the set does not list it. Whatever it throws reaches the verifier's caller unchanged.
    func key(for keyID: Data) async throws -> P256.Signing.PublicKey?
}

/// The COSE_KeySet identity.arkavo.net serves at `https://identity.arkavo.net/.well-known/cose-keys`: one CBOR array with nothing after it. An entry is
/// usable when it is a map with no repeated label, kty (1) EC2 (2), a non-empty byte-string kid (2), crv (−1) P-256 (1), and
/// 32-byte x (−2) and y (−3) that are a point on the curve. Other labels, alg included, are ignored. Unusable entries are
/// skipped; a set with no usable entry, or with a kid that two usable entries share, is unusable.
public enum IdentityKeySetParser {
    /// kid → key for each usable entry; nil when the set is unusable.
    public static func parse(_ data: Data) -> [Data: P256.Signing.PublicKey]? {
        var reader = CBORReader(bytes: Array(data))
        guard let item = try? reader.read(), reader.isAtEnd, case .array(let entries) = item else { return nil }
        var keys: [Data: P256.Signing.PublicKey] = [:]
        for entry in entries {
            guard let (keyID, key) = usableEntry(entry) else { continue }
            guard keys.updateValue(key, forKey: keyID) == nil else { return nil }
        }
        return keys.isEmpty ? nil : keys
    }

    private static func usableEntry(_ item: CBOR) -> (Data, P256.Signing.PublicKey)? {
        guard case .map(let pairs) = item else { return nil }
        var seen = Set<PasskeyCredentialAttestation.Label>()
        var keyID: CBOR?
        for (key, value) in pairs {
            guard let label = PasskeyCredentialAttestation.label(key), seen.insert(label).inserted else { return nil }
            if label == .uint(2) { keyID = value }
        }
        guard case .bytes(let keyID)? = keyID, !keyID.isEmpty,
              let key = PasskeyCredentialAttestation.publicKey(item) else { return nil }
        return (Data(keyID), key)
    }
}
