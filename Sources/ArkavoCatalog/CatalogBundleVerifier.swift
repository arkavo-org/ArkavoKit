import Foundation

/// A catalog v2 pointer whose bundle verified: identity.arkavo.net attested the passkey
/// `credentialID` for `pointer.owner`, and that passkey signed `pointer.bytes`. Its `seq` is not checked here.
public struct VerifiedCatalogPointer: Sendable, Equatable {
    public let pointer: CatalogPointer
    public let credentialID: Data
}

/// The trust decision for a creator's catalog v2 bundle. It reads no clock (it is given `now`),
/// logs nothing and compares text as UTF-8 bytes, never with `String ==`.
public enum CatalogBundleVerifier {
    /// Verifies `bundle` for the requested `subject`. The checks run in this order, and the first that fails ends
    /// verification with its own error:
    ///
    /// - the pointer (`.pointer`), then its owner against `subject` (`.pointerOwner`);
    /// - the attestation's envelope (`.attestationEnvelope`);
    /// - the key `keys` gives for the envelope's kid (`.unknownKey` when it lists none). Whatever the lookup throws
    ///   propagates unchanged;
    /// - the attestation's signature, claims and `iat` against `now`, in whole seconds (`.attestationSignature`,
    ///   `.attestationClaims`, `.attestationFromFuture`);
    /// - the attested sub against the owner (`.attestationSubject`), then the attested credential id against the
    ///   assertion's (`.credentialID`);
    /// - the assertion over the pointer bytes exactly as the bundle carried them, with the attested credential key, never
    ///   the IdP key (`WebAuthnAssertion.verify`).
    ///
    /// The bundle's JSON (`.malformed`) is `CatalogBundle.decode`'s, before this. The pointer's `issuedAt` is never compared
    /// with the clock, so a pointer issued in the future verifies.
    public static func verify(_ bundle: CatalogBundle, subject: String, keys: any IdentityKeyLookup,
                              now: Int64) async throws -> VerifiedCatalogPointer {
        let pointer = try CatalogPointer.decode(bundle.pointer)
        guard pointer.owner.utf8.elementsEqual(subject.utf8) else { throw CatalogBundleError.pointerOwner }
        let envelope = try PasskeyCredentialAttestation.envelope(bundle.attestation)
        guard let identityKey = try await keys.key(for: envelope.keyID) else { throw CatalogBundleError.unknownKey }
        let credential = try PasskeyCredentialAttestation.verify(envelope, key: identityKey, now: now)
        guard credential.subject.utf8.elementsEqual(pointer.owner.utf8) else {
            throw CatalogBundleError.attestationSubject
        }
        guard credential.credentialID.elementsEqual(bundle.credentialID) else { throw CatalogBundleError.credentialID }
        try WebAuthnAssertion.verify(pointer: pointer.bytes, authenticatorData: bundle.authenticatorData,
                                     clientDataJSON: bundle.clientDataJSON, signature: bundle.signature,
                                     key: credential.publicKey)
        return VerifiedCatalogPointer(pointer: pointer, credentialID: bundle.credentialID)
    }

    /// The reader's rollback rule: a verified pointer whose `seq` is lower than the highest this reader has seen for the
    /// creator is refused. An equal `seq` is the same pointer again.
    public static func checkRollback(_ pointer: VerifiedCatalogPointer, highestSeen: UInt64?) throws(CatalogBundleError) {
        if let highestSeen, pointer.pointer.seq < highestSeen { throw .rollback(highestSeen: highestSeen) }
    }
}
