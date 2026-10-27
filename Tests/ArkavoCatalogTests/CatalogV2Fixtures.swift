import CryptoKit
import Foundation
@testable import ArkavoCatalog

/// The catalog v2 vectors, byte for byte: the authnz-rs golden attestation, the golden-kid key set, the pointer `P7` with
/// its document `D97`, and the assertion pieces that bind to it. Assertion signatures are made at runtime and are verified,
/// never compared, because CryptoKit's ECDSA is randomized.
enum CatalogV2Fixture {
    static let subject = "0a1b2c3d-0000-4000-8000-000000000001"

    /// authnz-rs `GOLDEN_ATTESTATION`, 400 bytes: protected header `4..<74`, payload `78..<334`, signature `336..<400`.
    static let goldenAttestation = hex(
        "d2845846a3012603782a6170706c69636174696f6e2f61726b61766f2d706173736b65792d63726564656e7469616c2b63626f72045461726b61766f2d666978747572652d6b69642d31a0590100a763747970781961726b61766f2d706173736b65792d63726564656e7469616c63697373781b68747470733a2f2f6964656e746974792e61726b61766f2e6e657463737562782430613162326333642d303030302d343030302d383030302d3030303030303030303030316c63726564656e7469616c496450000102030405060708090a0b0c0d0e0f697075626c69634b6579a4010220012158201e18532fd4754c02f3041d9c75ceb33b83ffd81ac7ce4fe882ccb1c98bc5896e225820a46c311c4e2ff40dd96a3653e6e45445d32dfe486eced75c7a90c6a18881c0a36472704964736964656e746974792e61726b61766f2e6e6574636961741a68e778005840f568be35ab831986618bee8fc0b863cbb02169a3b8e870cc4a02a96982387707e21a8551a68a3f9c7349042b24bde95cba23692298a8df9760407c49d5821557")

    /// The IdP key `0x42`×32 as ANSI X9.63, and its `kid`.
    static let idpPublicKeyX963 = hex(
        "043ad3861a95621392516bb593ef05583ed2e5866f5cb6260a3017237fd89b90afd0961c7e37075a6791a39c61f56295b02b6d26567b615e60aa41ee1c8e83388d")
    static let goldenKID = Data("arkavo-fixture-kid-1".utf8)
    /// The IdP's private key, scalar `0x42`×32, which signed the golden attestation; `mintAttestation` signs with it.
    static let idpPrivateKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
    static let idpPublicKey = try! P256.Signing.PublicKey(x963Representation: idpPublicKeyX963)

    /// The live set's one key and its `kid` (identity.arkavo.net, 2026-10-18). It did not sign the golden attestation.
    static let liveKID = hex("d8313ee9b4c04c461a0eb00c5f26ce08f7abd670157c48d6b5824ecf7a1ba1b9")
    static let livePublicKeyX963 = hex(
        "049ad9d1e0320d8fa55210fc4ab44fa76233ef36aba2474c71d19c386d4115945c3cb9550f3653db28acf03ba0573c18a7a74599fda27c882879ff46020541ba8c")

    /// The golden credential key's coordinates: the public key of scalar `0x07`×32.
    static let credentialX = hex("1e18532fd4754c02f3041d9c75ceb33b83ffd81ac7ce4fe882ccb1c98bc5896e")
    static let credentialY = hex("a46c311c4e2ff40dd96a3653e6e45445d32dfe486eced75c7a90c6a18881c0a3")

    /// One key, built the way authnz-rs builds it (100 bytes).
    static let goldenKeySet = hex(
        "81a60102025461726b61766f2d666978747572652d6b69642d31032620012158203ad3861a95621392516bb593ef05583ed2e5866f5cb6260a3017237fd89b90af225820d0961c7e37075a6791a39c61f56295b02b6d26567b615e60aa41ee1c8e83388d")

    /// Fetched 2026-10-18 from identity.arkavo.net (113 bytes); for parsing only.
    static let liveKeySet = hex(
        "81a60102025820d8313ee9b4c04c461a0eb00c5f26ce08f7abd670157c48d6b5824ecf7a1ba1b9032620012158209ad9d1e0320d8fa55210fc4ab44fa76233ef36aba2474c71d19c386d4115945c2258203cb9550f3653db28acf03ba0573c18a7a74599fda27c882879ff46020541ba8c")

    /// The golden set followed by the live set's key: two entries, golden first.
    static let goldenAndLiveKeySet = Data([0x82]) + goldenKeySet.dropFirst() + liveKeySet.dropFirst()

    /// One COSE_KeySet entry in authnz-rs's label order: kty (1), kid (2), alg (3) = ES256, crv (−1), x (−2), y (−3), then
    /// `extra`. A nil kid is left out. The defaults are the golden entry, so `.array([keySetEntry()])` is `goldenKeySet`.
    static func keySetEntry(kid: Data? = goldenKID, kty: TestCBOR = .uint(2), crv: TestCBOR = .uint(1),
                            x: Data = idpPublicKeyX963[1..<33], y: Data = idpPublicKeyX963[33..<65],
                            extra: [(TestCBOR, TestCBOR)] = []) -> TestCBOR {
        var pairs: [(TestCBOR, TestCBOR)] = [(.uint(1), kty)]
        if let kid { pairs.append((.uint(2), .bytes(Array(kid)))) }
        pairs += [(.uint(3), .nint(6)), (.nint(0), crv), (.nint(1), .bytes(Array(x))), (.nint(2), .bytes(Array(y)))]
        return .map(pairs + extra)
    }

    /// `D97`: the 97-byte document that P7 names, and its BLAKE3. The bytes are here only for P7's `catalogHash` and
    /// `catalogSize`; they are an `arkavo.creator-catalog/1` document, which this library does not read, so no test
    /// decodes them.
    static let document = Data(
        #"{"schema":"arkavo.creator-catalog/1","owner":"0a1b2c3d-0000-4000-8000-000000000001","entries":[]}"#.utf8)
    static let documentHash = "729d79721d28362279f6e2a5a9e0f7b64a7e9097adfa67207f41b615618d01e7"

    /// `P7`: 224 bytes, seq 7, `issuedAt` 2026-10-19T01:02:03Z (1_792_371_723).
    static let pointerText = #"{"schema":"arkavo.catalog-pointer/1","owner":"0a1b2c3d-0000-4000-8000-000000000001","seq":7,"catalogHash":"729d79721d28362279f6e2a5a9e0f7b64a7e9097adfa67207f41b615618d01e7","catalogSize":97,"issuedAt":"2026-10-19T01:02:03Z"}"#
    static let pointer = Data(pointerText.utf8)
    static let pointerChallenge = "Yr1koKp9uD2rVhlmnadp8PuvwhuaNRhrGE2FgLm5DTw"
    /// P7's `issuedAt`.
    static let pointerIssuedAt = Date(timeIntervalSince1970: 1_792_371_723)

    /// A pointer in P7's key order with the given values; the defaults are P7 itself, byte for byte.
    static func makePointer(owner: String = subject, seq: UInt64 = 7, catalogHash: String = documentHash,
                            catalogSize: Int = 97, issuedAt: String = "2026-10-19T01:02:03Z") -> Data {
        Data(#"{"schema":"arkavo.catalog-pointer/1","owner":"\#(owner)","seq":\#(seq),"catalogHash":"\#(catalogHash)","catalogSize":\#(catalogSize),"issuedAt":"\#(issuedAt)"}"#.utf8)
    }

    /// `C7`: the client data that signs P7's SHA-256.
    static let clientDataText = #"{"type":"webauthn.get","challenge":"Yr1koKp9uD2rVhlmnadp8PuvwhuaNRhrGE2FgLm5DTw","origin":"https://identity.arkavo.net"}"#
    static let clientData = Data(clientDataText.utf8)

    /// `A`: 37 bytes, rpIdHash of `identity.arkavo.net`, flags `0x05` (UP and UV), counter 0.
    static let authenticatorData = hex("496676630158193beba7c3e062dd5fe42f2385cd2986aee21cbe3258646180c80500000000")

    /// The credential's private key: scalar `0x07`×32.
    static let credentialPrivateKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x07, count: 32))

    /// The credential id the golden attestation binds: bytes `00…0f`.
    static let credentialID = Data(0..<16)

    /// A second passkey of the same creator: scalar `0x0B`×32, with the credential id `0B`×16.
    static let secondCredentialPrivateKey = try! P256.Signing.PrivateKey(
        rawRepresentation: Data(repeating: 0x0B, count: 32))
    static let secondCredentialID = Data(repeating: 0x0B, count: 16)

    /// The DER signature of `authenticatorData ‖ SHA256(clientData)` by the credential key; different bytes on every call.
    static func assertionSignature(authenticatorData: Data = authenticatorData, clientData: Data = clientData,
                                   key: P256.Signing.PrivateKey = credentialPrivateKey) -> Data {
        let message = authenticatorData + Data(SHA256.hash(data: clientData))
        return (try! key.signature(for: message)).derRepresentation
    }

    /// A bundle's JSON from raw field text, so a test can break one field.
    static func bundleJSON(pointer: String, credentialID: String, authenticatorData: String, clientDataJSON: String,
                           signature: String, credential: String) -> Data {
        Data(#"{"pointer":"\#(pointer)","assertion":{"credentialId":"\#(credentialID)","authenticatorData":"\#(authenticatorData)","clientDataJSON":"\#(clientDataJSON)","signature":"\#(signature)"},"credential":"\#(credential)"}"#.utf8)
    }

    /// The contract-shaped bundle for P7. The assertion is signed at runtime over the given pieces.
    static func bundle(pointer: Data = pointer, clientData: Data? = nil, authenticatorData: Data = authenticatorData,
                       credentialID: Data = credentialID, credential: Data = goldenAttestation,
                       key: P256.Signing.PrivateKey = credentialPrivateKey) -> Data {
        let clientData = clientData ?? Data(
            #"{"type":"webauthn.get","challenge":"\#(Base64URL.encode(Data(SHA256.hash(data: pointer))))","origin":"https://identity.arkavo.net"}"#.utf8)
        return bundleJSON(
            pointer: Base64URL.encode(pointer), credentialID: Base64URL.encode(credentialID),
            authenticatorData: Base64URL.encode(authenticatorData), clientDataJSON: Base64URL.encode(clientData),
            signature: Base64URL.encode(assertionSignature(authenticatorData: authenticatorData, clientData: clientData,
                                                          key: key)),
            credential: Base64URL.encode(credential))
    }

    // MARK: Attestations minted here

    /// The golden protected header's labels, in its order: alg ES256 (−7), content type, kid.
    static let goldenProtected: [(TestCBOR, TestCBOR)] = [
        (.uint(1), .nint(6)),
        (.uint(3), .text("application/arkavo-passkey-credential+cbor")),
        (.uint(4), .bytes(Array(goldenKID))),
    ]

    /// The golden attestation's claims, in authnz-rs's order.
    static let goldenClaims: [(TestCBOR, TestCBOR)] = [
        (.text("typ"), .text("arkavo-passkey-credential")),
        (.text("iss"), .text("https://identity.arkavo.net")),
        (.text("sub"), .text(subject)),
        (.text("credentialId"), .bytes(Array(credentialID))),
        (.text("publicKey"), coseKey()),
        (.text("rpId"), .text("identity.arkavo.net")),
        (.text("iat"), .uint(1_760_000_000)),
    ]

    /// The golden claims with the claim named `name` replaced by `pair`, in place, or removed when `pair` is nil.
    static func goldenClaims(replacing name: String, with pair: (TestCBOR, TestCBOR)?) -> [(TestCBOR, TestCBOR)] {
        goldenClaims.compactMap { claim in
            guard case .text(let key) = claim.0, key == name else { return claim }
            return pair
        }
    }

    /// The golden claims with `name`'s value replaced.
    static func goldenClaims(_ name: String, _ value: TestCBOR) -> [(TestCBOR, TestCBOR)] {
        goldenClaims(replacing: name, with: (.text(name), value))
    }

    /// An EC2 COSE_Key in authnz-rs's label order: kty, crv, x, y, then `extra`.
    static func coseKey(kty: TestCBOR = .uint(2), crv: TestCBOR = .uint(1), x: Data = credentialX, y: Data = credentialY,
                        extra: [(TestCBOR, TestCBOR)] = []) -> TestCBOR {
        .map([(.uint(1), kty), (.nint(0), crv), (.nint(1), .bytes(Array(x))), (.nint(2), .bytes(Array(y)))] + extra)
    }

    /// A COSE_Sign1 of `protected` and `payload`, exactly as given, signed by `signer` (raw r‖s) over a Sig_structure this
    /// fixture builds itself, so a minted attestation does not depend on the code under test.
    static func signAttestation(protected: Data, payload: Data, unprotected: TestCBOR = .map([]), tag: UInt64? = 18,
                                signer: P256.Signing.PrivateKey = idpPrivateKey) -> Data {
        let toSign = TestCBOR.array([.text("Signature1"), .bytes(Array(protected)), .bytes([]), .bytes(Array(payload))]).data
        let signature = (try! signer.signature(for: toSign)).rawRepresentation
        let body = TestCBOR.array([.bytes(Array(protected)), unprotected, .bytes(Array(payload)), .bytes(Array(signature))])
        return (tag.map { TestCBOR.tag($0, body) } ?? body).data
    }

    /// An attestation whose protected header carries the given labels in the order 1, 2, 3, 4 (a nil one is left out). The
    /// defaults are the golden header and claims, so `mintAttestation().prefix(336)` is the golden encoding.
    static func mintAttestation(claims: TestCBOR = .map(goldenClaims), kid: TestCBOR? = .bytes(Array(goldenKID)),
                                contentType: TestCBOR? = .text("application/arkavo-passkey-credential+cbor"),
                                alg: TestCBOR? = .nint(6), crit: TestCBOR? = nil, tag: UInt64? = 18,
                                signer: P256.Signing.PrivateKey = idpPrivateKey) -> Data {
        let labels: [(UInt64, TestCBOR?)] = [(1, alg), (2, crit), (3, contentType), (4, kid)]
        let header = TestCBOR.map(labels.compactMap { label, value in value.map { (.uint(label), $0) } })
        return signAttestation(protected: header.data, payload: claims.data, tag: tag, signer: signer)
    }

    /// An attestation under the golden header that `subject`'s credential `credentialID` has `credentialKey`'s public key,
    /// issued at `iat` and signed by `signer`. The defaults are the golden claims, so its first 336 bytes are the golden ones.
    static func mintCredentialAttestation(subject: String = subject, credentialID: Data = credentialID,
                                          credentialKey: P256.Signing.PrivateKey = credentialPrivateKey,
                                          iat: UInt64 = 1_760_000_000,
                                          signer: P256.Signing.PrivateKey = idpPrivateKey) -> Data {
        let x963 = credentialKey.publicKey.x963Representation
        let values: [String: TestCBOR] = [
            "sub": .text(subject), "credentialId": .bytes(Array(credentialID)),
            "publicKey": coseKey(x: x963[1..<33], y: x963[33..<65]), "iat": .uint(iat),
        ]
        let claims = goldenClaims.map { claim -> (TestCBOR, TestCBOR) in
            guard case .text(let name) = claim.0, let value = values[name] else { return claim }
            return (claim.0, value)
        }
        return mintAttestation(claims: .map(claims), signer: signer)
    }

    static func hex(_ text: String) -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}

/// What `StaticKeys` throws when it is told to: a stand-in for a key set the caller could not fetch.
enum KeyLookupFailure: Error, Sendable, Equatable {
    case unavailable
}

/// An `IdentityKeyLookup` that answers from a fixed map, or throws `error` when one is given, and records each kid asked for.
actor StaticKeys: IdentityKeyLookup {
    private let keys: [Data: P256.Signing.PublicKey]
    private let error: (any Error & Sendable)?
    private(set) var requests: [Data] = []

    init(_ keys: [Data: P256.Signing.PublicKey], throwing error: (any Error & Sendable)? = nil) {
        self.keys = keys
        self.error = error
    }

    /// The golden kid's IdP key, `0x42`.
    static func golden() -> StaticKeys { StaticKeys([CatalogV2Fixture.goldenKID: CatalogV2Fixture.idpPublicKey]) }

    func key(for keyID: Data) async throws -> P256.Signing.PublicKey? {
        requests.append(keyID)
        if let error { throw error }
        return keys[keyID]
    }
}
