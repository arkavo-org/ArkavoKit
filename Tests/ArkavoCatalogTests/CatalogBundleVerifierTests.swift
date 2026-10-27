import CryptoKit
import Foundation
import Testing
@testable import ArkavoCatalog

/// The whole catalog v2 chain: the pointer and its owner, the IdP's attestation under the key
/// the key set lists for its kid, the attested sub and credential id, then the passkey's assertion over the exact pointer
/// bytes, in that order. Every case starts from the golden chain (P7, C7, A and the golden attestation under the IdP key
/// `0x42`) and breaks what it names. Assertions are signed at run time over the pieces given, so only the named check fails.
struct CatalogBundleVerifierTests {
    private typealias Fixture = CatalogV2Fixture

    /// Later than the golden `iat`.
    private static let now: Int64 = 1_800_000_000
    private static let otherSubject = "5c1f0e7a-2b8d-4c0f-9a51-3f2b6d8e4a10"
    /// The golden credential id's length, other bytes.
    private static let otherCredentialID = Data(repeating: 0xEE, count: 16)
    /// An IdP key that is not the one the golden kid names.
    private static let otherIdPKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x43, count: 32))
    /// A challenge that is not over the pointer bytes.
    private static let otherChallenge = Base64URL.encode(Data(SHA256.hash(data: Data("not the pointer".utf8))))

    /// `K` (U+004B) and the Kelvin sign (U+212A) are canonically equivalent, so Swift's `==` calls these two subjects equal.
    /// Their UTF-8 bytes differ, and the verifier compares bytes.
    private static let asciiOwner = "creator-K"
    private static let kelvinOwner = "creator-\u{212A}"

    /// The key lookup a case uses. Each case gets a fresh one, which records the kids asked for.
    enum Keys: Sendable {
        /// The golden kid's IdP key.
        case golden
        /// Only the live kid's key; the golden kid is not listed.
        case liveOnly
        /// A lookup that throws `.unavailable`.
        case unavailable

        func make() -> StaticKeys {
            switch self {
            case .golden: .golden()
            case .liveOnly:
                StaticKeys([Fixture.liveKID: try! P256.Signing.PublicKey(x963Representation: Fixture.livePublicKeyX963)])
            case .unavailable: StaticKeys([:], throwing: KeyLookupFailure.unavailable)
            }
        }
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let label: String
        let bundle: Data
        let subject: String
        let keys: Keys
        let expected: CatalogBundleError
        init(_ label: String, _ bundle: Data, subject: String = Fixture.subject, keys: Keys = .golden,
             _ expected: CatalogBundleError) {
            self.label = label
            self.bundle = bundle
            self.subject = subject
            self.keys = keys
            self.expected = expected
        }
        var testDescription: String { label }
    }

    private static func verify(_ bundle: Data, subject: String = Fixture.subject, keys: StaticKeys = .golden(),
                               now: Int64 = now) async throws -> VerifiedCatalogPointer {
        try await CatalogBundleVerifier.verify(try CatalogBundle.decode(bundle), subject: subject, keys: keys, now: now)
    }

    /// C7's members with `challenge` and `origin` replaced.
    private static func clientData(challenge: String = Fixture.pointerChallenge,
                                   origin: String = "https://identity.arkavo.net") -> Data {
        Data(#"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(origin)"}"#.utf8)
    }

    /// A with the RP ID hash of `rpID` and the flags `flags`.
    private static func authenticatorData(rpID: String = "identity.arkavo.net", flags: UInt8 = 0x05) -> Data {
        Data(SHA256.hash(data: Data(rpID.utf8))) + Data([flags, 0x00, 0x00, 0x00, 0x00])
    }

    // MARK: Accepted

    @Test
    func theGoldenChainVerifies() async throws {
        let keys = StaticKeys.golden()
        let verified = try await Self.verify(Fixture.bundle(clientData: Fixture.clientData), keys: keys)
        #expect(verified.pointer.seq == 7)
        #expect(verified.pointer.catalogHash == "729d79721d28362279f6e2a5a9e0f7b64a7e9097adfa67207f41b615618d01e7")
        #expect(verified.pointer.catalogSize == 97)
        #expect(verified.credentialID == Data(0..<16))
        #expect(verified.pointer.bytes == Fixture.pointer)
        #expect(Array(verified.pointer.owner.utf8) == Array(Fixture.subject.utf8))
        #expect(await keys.requests == [Fixture.goldenKID])
    }

    @Test
    func aPointerIssuedInTheFutureStillVerifies() async throws {
        let pointer = Fixture.makePointer(issuedAt: "2099-01-01T00:00:00Z")
        let verified = try await Self.verify(Fixture.bundle(pointer: pointer))
        #expect(verified.pointer.issuedAt == Date(timeIntervalSince1970: 4_070_908_800))
        #expect(verified.pointer.seq == 7)
    }

    @Test
    func aNewPasskeyForTheSameCreatorVerifies() async throws {
        let attestation = Fixture.mintCredentialAttestation(
            credentialID: Fixture.secondCredentialID, credentialKey: Fixture.secondCredentialPrivateKey)
        let bundle = Fixture.bundle(pointer: Fixture.makePointer(seq: 8), credentialID: Fixture.secondCredentialID,
                                    credential: attestation, key: Fixture.secondCredentialPrivateKey)
        let verified = try await Self.verify(bundle)
        #expect(verified.pointer.seq == 8)
        #expect(verified.credentialID == Fixture.secondCredentialID)
    }

    @Test
    func theAssertionIsCheckedOverThePointerBytesAsReceived() async throws {
        // P7's members in another order, inside whitespace. The passkey signed these bytes; a re-serialization would not hash
        // to the challenge.
        let pointer = Data(
            "\n {\"seq\":7,\"issuedAt\":\"2026-10-19T01:02:03Z\",\"catalogSize\":97,\"owner\":\"\(Fixture.subject)\",\"catalogHash\":\"\(Fixture.documentHash)\",\"schema\":\"arkavo.catalog-pointer/1\"} \t".utf8)
        let verified = try await Self.verify(Fixture.bundle(pointer: pointer))
        #expect(verified.pointer.bytes == pointer)
        #expect(verified.pointer.seq == 7)
    }

    @Test
    func theAttestationsIatIsCheckedAgainstNow() async throws {
        // The golden iat is 1_760_000_000; it may lie at most 60 s after `now`.
        _ = try await Self.verify(Fixture.bundle(), now: 1_760_000_000 - 60)
        await #expect(throws: CatalogBundleError.attestationFromFuture) {
            try await Self.verify(Fixture.bundle(), now: 1_760_000_000 - 61)
        }
    }

    // MARK: Refused

    /// Forged or misdirected bundles, each refused by the first check that fails.
    private static let forgeries: [Case] = [
        Case("a challenge over other bytes", Fixture.bundle(clientData: clientData(challenge: otherChallenge)),
             .challenge),
        Case("the RP ID hash of another relying party",
             Fixture.bundle(authenticatorData: authenticatorData(rpID: "evil.example")), .rpIDHash),
        Case("another origin", Fixture.bundle(clientData: clientData(origin: "https://evil.example")), .origin),
        Case("user presence without user verification", Fixture.bundle(authenticatorData: authenticatorData(flags: 0x01)),
             .userVerification),
        Case("another subject's pointer under the golden attestation",
             Fixture.bundle(pointer: Fixture.makePointer(owner: otherSubject)), subject: otherSubject,
             .attestationSubject),
        Case("a requested subject that is not the owner", Fixture.bundle(), subject: otherSubject, .pointerOwner),
    ]

    @Test(arguments: forgeries)
    func refusesEachForgery(_ test: Case) async {
        let keys = test.keys.make()
        await #expect(throws: test.expected) { try await Self.verify(test.bundle, subject: test.subject, keys: keys) }
    }

    @Test
    func anAttestationUnderAnUnlistedKidIsUnknownKey() async {
        let keys = Keys.liveOnly.make()
        await #expect(throws: CatalogBundleError.unknownKey) { try await Self.verify(Fixture.bundle(), keys: keys) }
        #expect(await keys.requests == [Fixture.goldenKID])
    }

    @Test
    func aLookupThatThrowsPropagatesUnchanged() async {
        let keys = Keys.unavailable.make()
        await #expect(throws: KeyLookupFailure.unavailable) { try await Self.verify(Fixture.bundle(), keys: keys) }
        #expect(await keys.requests == [Fixture.goldenKID])
    }

    @Test
    func anAssertionByAnotherPasskeyUnderThisAttestationFails() async {
        let bundle = Fixture.bundle(credentialID: Fixture.credentialID, credential: Fixture.goldenAttestation,
                                    key: Fixture.secondCredentialPrivateKey)
        await #expect(throws: CatalogBundleError.assertionSignature) { try await Self.verify(bundle) }
    }

    /// `0102`, then the attested id `00…0f` less its last byte and with a byte added.
    @Test(arguments: [Data([0x01, 0x02]), Data(0..<15), Data(0..<17)])
    func anAttestationForAnotherCredentialIDFails(_ credentialID: Data) async {
        let bundle = Fixture.bundle(credentialID: credentialID)
        await #expect(throws: CatalogBundleError.credentialID) { try await Self.verify(bundle) }
    }

    /// Subjects whose UTF-8 bytes are not `creator-K`'s: the Kelvin sign, a prefix and an extension.
    private static let nearOwners = [kelvinOwner, "creator-", "creator-KK"]

    @Test(arguments: nearOwners)
    func aRequestedSubjectThatIsNotTheOwnersBytesIsRefused(_ subject: String) async throws {
        #expect(Self.asciiOwner == Self.kelvinOwner)
        let bundle = Fixture.bundle(pointer: Fixture.makePointer(owner: Self.asciiOwner),
                                    credential: Fixture.mintCredentialAttestation(subject: Self.asciiOwner))
        _ = try await Self.verify(bundle, subject: Self.asciiOwner)
        await #expect(throws: CatalogBundleError.pointerOwner) { try await Self.verify(bundle, subject: subject) }
    }

    @Test(arguments: nearOwners)
    func anAttestedSubThatIsNotTheOwnersBytesIsRefused(_ sub: String) async {
        let bundle = Fixture.bundle(pointer: Fixture.makePointer(owner: Self.asciiOwner),
                                    credential: Fixture.mintCredentialAttestation(subject: sub))
        await #expect(throws: CatalogBundleError.attestationSubject) {
            try await Self.verify(bundle, subject: Self.asciiOwner)
        }
    }

    // MARK: Order

    /// Each case breaks two checks in a row and expects the earlier one's error. A case that uses the throwing lookup and
    /// expects an error from before the lookup also shows that the lookup was never made.
    private static let ordered: [Case] = [
        Case("an invalid pointer and an attestation that is not COSE",
             Fixture.bundle(pointer: Data("{}".utf8), credential: Data([0x00])), keys: .unavailable, .pointer),
        Case("another owner and an assertion by another passkey",
             Fixture.bundle(key: Fixture.secondCredentialPrivateKey), subject: otherSubject, keys: .unavailable,
             .pointerOwner),
        Case("another owner and an attestation that is not COSE", Fixture.bundle(credential: Data([0x00])),
             subject: otherSubject, keys: .unavailable, .pointerOwner),
        Case("an attestation that is not COSE and a lookup that throws", Fixture.bundle(credential: Data([0x00])),
             keys: .unavailable, .attestationEnvelope),
        Case("an unlisted kid and a signature by another IdP key",
             Fixture.bundle(credential: Fixture.mintCredentialAttestation(signer: otherIdPKey)), keys: .liveOnly,
             .unknownKey),
        Case("a signature by another IdP key and another sub",
             Fixture.bundle(credential: Fixture.mintCredentialAttestation(subject: otherSubject, signer: otherIdPKey)),
             .attestationSignature),
        Case("an iat from the future and another sub",
             Fixture.bundle(credential: Fixture.mintCredentialAttestation(subject: otherSubject, iat: UInt64(now) + 61)),
             .attestationFromFuture),
        Case("another sub and another credential id",
             Fixture.bundle(credentialID: otherCredentialID,
                            credential: Fixture.mintCredentialAttestation(subject: otherSubject)),
             .attestationSubject),
        Case("another credential id and a challenge over other bytes",
             Fixture.bundle(clientData: clientData(challenge: otherChallenge), credentialID: otherCredentialID),
             .credentialID),
        Case("another credential id and an assertion by another passkey",
             Fixture.bundle(credentialID: otherCredentialID, key: Fixture.secondCredentialPrivateKey), .credentialID),
    ]

    @Test(arguments: ordered)
    func checksRunInOrder(_ test: Case) async {
        let keys = test.keys.make()
        await #expect(throws: test.expected) { try await Self.verify(test.bundle, subject: test.subject, keys: keys) }
        if test.keys == .unavailable { #expect(await keys.requests.isEmpty) }
    }

    // MARK: Built here

    /// What a publisher sends: a pointer from the builder and a bundle from the initializer, as `encoded()` writes it.
    @Test
    func aBundleBuiltAndEncodedHereVerifies() async throws {
        let pointer = try CatalogPointer(owner: Fixture.subject, seq: 8, catalogHash: Fixture.documentHash,
                                         catalogSize: 97, issuedAt: Fixture.pointerIssuedAt)
        let challenge = Base64URL.encode(Data(SHA256.hash(data: pointer.bytes)))
        let clientData = Self.clientData(challenge: challenge)
        let bundle = try CatalogBundle(pointer: pointer.bytes, credentialID: Fixture.credentialID,
                                       authenticatorData: Fixture.authenticatorData, clientDataJSON: clientData,
                                       signature: Fixture.assertionSignature(clientData: clientData),
                                       attestation: Fixture.goldenAttestation)
        let verified = try await Self.verify(bundle.encoded())
        #expect(verified.pointer == pointer)
        #expect(verified.credentialID == Fixture.credentialID)
    }

    // MARK: Rollback

    /// P7 (seq 7) after a reader has seen a higher seq for its creator.
    @Test(arguments: [8, 9, CatalogPointer.maxSeq, UInt64.max] as [UInt64])
    func aLowerSeqThanTheHighestSeenIsARollback(_ highestSeen: UInt64) async throws {
        let verified = try await Self.verify(Fixture.bundle())
        #expect(verified.pointer.seq == 7)
        #expect(throws: CatalogBundleError.rollback(highestSeen: highestSeen)) {
            try CatalogBundleVerifier.checkRollback(verified, highestSeen: highestSeen)
        }
    }

    /// P7 when the reader has seen nothing, a lower seq, or seq 7 itself (the same pointer again).
    @Test(arguments: [nil, 0, 1, 6, 7] as [UInt64?])
    func anEqualOrHigherSeqIsNotARollback(_ highestSeen: UInt64?) async throws {
        let verified = try await Self.verify(Fixture.bundle())
        #expect(verified.pointer.seq == 7)
        try CatalogBundleVerifier.checkRollback(verified, highestSeen: highestSeen)
    }
}
