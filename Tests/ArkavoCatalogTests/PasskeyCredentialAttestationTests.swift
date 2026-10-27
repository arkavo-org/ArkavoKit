import CryptoKit
import Foundation
import Testing
@testable import ArkavoCatalog

/// identity.arkavo.net's COSE_Sign1 passkey credential attestation: authnz-rs's golden vector,
/// and attestations minted here with the fixture IdP key `0x42`, each validly signed so that only the rule under test fails.
struct PasskeyCredentialAttestationTests {
    private typealias Fixture = CatalogV2Fixture
    private typealias Attestation = PasskeyCredentialAttestation

    /// Later than the golden `iat`, as in authnz-rs's fixture.
    private static let later: Int64 = 1_800_000_000
    private static let golden = Fixture.goldenAttestation
    private static let contentType = "application/arkavo-passkey-credential+cbor"

    private static func verify(_ bytes: Data, key: P256.Signing.PublicKey = Fixture.idpPublicKey,
                               now: Int64 = later) throws -> PasskeyCredential {
        try Attestation.verify(try Attestation.envelope(bytes), key: key, now: now)
    }

    private static func minted(_ claims: [(TestCBOR, TestCBOR)]) -> Data {
        Fixture.mintAttestation(claims: .map(claims))
    }

    private static func signed(protected: [(TestCBOR, TestCBOR)]) -> Data {
        Fixture.signAttestation(protected: TestCBOR.map(protected).data, payload: TestCBOR.map(Fixture.goldenClaims).data)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let label: String
        let bytes: Data
        init(_ label: String, _ bytes: Data) { self.label = label; self.bytes = bytes }
        var testDescription: String { label }
    }

    // MARK: The golden vector

    @Test
    func goldenAttestationVerifies() throws {
        let envelope = try Attestation.envelope(Self.golden)
        #expect(envelope.keyID == Data("arkavo-fixture-kid-1".utf8))
        let credential = try Attestation.verify(envelope, key: Fixture.idpPublicKey, now: 1_800_000_000)
        #expect(Array(credential.subject.utf8) == Array("0a1b2c3d-0000-4000-8000-000000000001".utf8))
        #expect(credential.credentialID == Data(0..<16))
        #expect(credential.issuedAt == 1_760_000_000)
        #expect(credential.publicKey.x963Representation == Fixture.hex(
            "041e18532fd4754c02f3041d9c75ceb33b83ffd81ac7ce4fe882ccb1c98bc5896ea46c311c4e2ff40dd96a3653e6e45445d32dfe486eced75c7a90c6a18881c0a3"))
        #expect(credential.publicKey.x963Representation == Fixture.credentialPrivateKey.publicKey.x963Representation)
    }

    @Test
    func theConstantsAreTheContractValues() {
        #expect(Attestation.contentType == "application/arkavo-passkey-credential+cbor")
        #expect(Attestation.typ == "arkavo-passkey-credential")
        #expect(Attestation.issuer == "https://identity.arkavo.net")
        #expect(Attestation.relyingPartyID == "identity.arkavo.net")
        #expect(Attestation.maxClockSkew == 60)
    }

    @Test
    func sigStructureOfTheGoldenVector() throws {
        let structure = Attestation.sigStructure(protected: Self.golden[4..<74], payload: Self.golden[78..<334])
        #expect(structure.count == 344)
        #expect(Data(SHA256.hash(data: structure))
            == Fixture.hex("7c640dd8405e4f162869a1ba1a2eb2f81f4b54203afeb957d8a88a88ca19e50b"))
        let envelope = try Attestation.envelope(Self.golden)
        #expect(envelope.protected == Self.golden[4..<74])
        #expect(envelope.payload == Self.golden[78..<334])
        #expect(envelope.signature.rawRepresentation == Self.golden[336..<400])
    }

    @Test(arguments: [0, 1, 23, 24, 255, 256, 65_535, 65_536])
    func sigStructureUsesShortestFormHeads(_ count: Int) {
        let protected = Data(repeating: 0xA0, count: count)
        let payload = Data(repeating: 0x01, count: 3)
        let expected = TestCBOR.array([.text("Signature1"), .bytes(Array(protected)), .bytes([]), .bytes(Array(payload))]).data
        #expect(Attestation.sigStructure(protected: protected, payload: payload) == expected)
        let head: [UInt8] = switch count {
        case 0..<24: [0x40 | UInt8(count)]
        case 24...255: [0x58, UInt8(count)]
        case 256...65_535: [0x59, UInt8(count >> 8), UInt8(count & 0xFF)]
        default: [0x5A, 0x00, 0x01, 0x00, 0x00]
        }
        #expect(Array(expected[12..<(12 + head.count)]) == head)
    }

    @Test
    func untaggedVerifies() throws {
        let untagged = Self.golden.dropFirst()
        #expect(try Attestation.envelope(untagged).keyID == Fixture.goldenKID)
        #expect(try Self.verify(untagged).issuedAt == 1_760_000_000)
        #expect(try Self.verify(Fixture.mintAttestation(tag: nil)).credentialID == Fixture.credentialID)
    }

    @Test
    func mintedGoldenMatchesTheGoldenEncoding() throws {
        #expect(TestCBOR.map(Fixture.goldenProtected).data == Self.golden[4..<74])
        #expect(TestCBOR.map(Fixture.goldenClaims).data == Self.golden[78..<334])
        let minted = Fixture.mintAttestation()
        #expect(minted.count == 400)
        #expect(minted.prefix(336) == Self.golden.prefix(336))
        let credential = try Self.verify(minted)
        #expect(credential.issuedAt == 1_760_000_000)
        #expect(credential.credentialID == Fixture.credentialID)
    }

    @Test
    func descriptionIsFixed() throws {
        let envelope = try Attestation.envelope(Self.golden)
        #expect(String(describing: envelope) == "Credential attestation")
        #expect(String(reflecting: envelope) == "Credential attestation")
        #expect(Mirror(reflecting: envelope).children.isEmpty)
        #expect("\(envelope)" == "Credential attestation")
    }

    // MARK: The envelope

    private static let envelopeRefusals: [Case] = {
        let golden = Self.golden
        var unprotectedArray = golden
        unprotectedArray[74] = 0x80
        let untagged = golden.dropFirst()
        return [
            .init("the CWT tag 61 over the untagged bytes", Data([0xD8, 0x3D]) + untagged),
            .init("the CWT tag 61 over the tagged bytes", Data([0xD8, 0x3D]) + golden),
            .init("tag 98", Data([0xD8, 0x62]) + untagged),
            .init("tag 18 twice", Data([0xD2]) + golden),
            .init("a trailing 00", golden + Data([0x00])),
            .init("a 3-element array", Data([0xD2, 0x83]) + golden[2..<334]),
            .init("a 5-element array", Data([0xD2, 0x85]) + golden[2..<400] + Data([0x40])),
            .init("a 63-byte signature", golden.prefix(334) + Data([0x58, 0x3F]) + golden[336..<399]),
            .init("a 65-byte signature", golden.prefix(334) + Data([0x58, 0x41]) + golden[336..<400] + Data([0x00])),
            .init("an empty signature", golden.prefix(334) + Data([0x40])),
            .init("a text signature", golden.prefix(334) + TestCBOR.text(String(repeating: "a", count: 64)).data),
            .init("an unprotected array", unprotectedArray),
            .init("a nil (detached) payload", TestCBOR.tag(18, .array([
                .bytes(Array(golden[4..<74])), .map([]), .raw([0xF6]), .bytes(Array(golden[336..<400]))])).data),
            .init("a text protected header", TestCBOR.tag(18, .array([
                .text("protected"), .map([]), .bytes(Array(golden[78..<334])), .bytes(Array(golden[336..<400]))])).data),
            .init("a map, not an array", TestCBOR.map([]).data),
            .init("empty input", Data()),
            .init("a truncated envelope", golden.prefix(399)),
            .init("no content type", Fixture.mintAttestation(contentType: nil)),
            .init("content type application/cwt", Fixture.mintAttestation(contentType: .text("application/cwt"))),
            .init("content type as the CoAP number 61", Fixture.mintAttestation(contentType: .uint(61))),
            .init("content type with a trailing space", Fixture.mintAttestation(contentType: .text(contentType + " "))),
            .init("content type in upper case", Fixture.mintAttestation(contentType: .text(contentType.uppercased()))),
            .init("alg −35 (ES384)", Fixture.mintAttestation(alg: .nint(34))),
            .init("alg +7", Fixture.mintAttestation(alg: .uint(7))),
            .init("alg as the text ES256", Fixture.mintAttestation(alg: .text("ES256"))),
            .init("no alg", Fixture.mintAttestation(alg: nil)),
            .init("a crit label", Fixture.mintAttestation(crit: .array([.uint(3)]))),
            .init("an empty crit label", Fixture.mintAttestation(crit: .array([]))),
            .init("no kid", Fixture.mintAttestation(kid: nil)),
            .init("an empty kid", Fixture.mintAttestation(kid: .bytes([]))),
            .init("a text kid", Fixture.mintAttestation(kid: .text("arkavo-fixture-kid-1"))),
            .init("a protected map that repeats label 1", signed(protected: [(.uint(1), .nint(6))] + Fixture.goldenProtected)),
            .init("a protected map that repeats label 4", signed(protected: Fixture.goldenProtected + [(.uint(4), .bytes([1]))])),
            .init("a protected map that repeats a text label",
                  signed(protected: Fixture.goldenProtected + [(.text("x"), .uint(0)), (.text("x"), .uint(0))])),
            .init("a protected map with a byte-string label",
                  signed(protected: Fixture.goldenProtected + [(.bytes([1]), .uint(0))])),
            .init("a protected header with a trailing byte", Fixture.signAttestation(
                protected: TestCBOR.map(Fixture.goldenProtected).data + Data([0x00]),
                payload: TestCBOR.map(Fixture.goldenClaims).data)),
            .init("an empty protected header", Fixture.signAttestation(
                protected: Data(), payload: TestCBOR.map(Fixture.goldenClaims).data)),
            .init("a protected header that is an array", Fixture.signAttestation(
                protected: TestCBOR.array([.uint(1), .nint(6)]).data, payload: TestCBOR.map(Fixture.goldenClaims).data)),
            .init("an indefinite-length array", Data([0xD2, 0x9F]) + golden[2..<400] + Data([0xFF])),
            .init("an indefinite-length signature",
                  golden.prefix(334) + Data([0x5F, 0x58, 0x40]) + golden[336..<400] + Data([0xFF])),
            .init("a protected header nested 17 levels deep",
                  signed(protected: Fixture.goldenProtected + [(.uint(99), nested(16))])),
        ]
    }()

    /// `levels` arrays around a uint. As a protected label's value, the uint sits `levels + 1` levels below the header map,
    /// and CBORReader reads at most 16.
    private static func nested(_ levels: Int) -> TestCBOR {
        (0..<levels).reduce(TestCBOR.uint(0)) { inner, _ in .array([inner]) }
    }

    @Test(arguments: envelopeRefusals)
    func refusesWhatIsNotAnAttestationEnvelope(_ refusal: Case) {
        #expect(throws: CatalogBundleError.attestationEnvelope) { try Attestation.envelope(refusal.bytes) }
    }

    private static let acceptedEnvelopes: [Case] = [
        .init("untagged", Fixture.mintAttestation(tag: nil)),
        .init("protected labels in another order", signed(protected: Fixture.goldenProtected.reversed())),
        .init("other protected labels", signed(protected: Fixture.goldenProtected + [
            (.uint(5), .bytes([UInt8](repeating: 0, count: 16))), (.nint(9), .uint(1)), (.text("note"), .text("x"))])),
        .init("a non-empty unprotected map", Fixture.signAttestation(
            protected: TestCBOR.map(Fixture.goldenProtected).data, payload: TestCBOR.map(Fixture.goldenClaims).data,
            unprotected: .map([(.uint(4), .bytes(Array("another-kid".utf8))), (.uint(1), .nint(34)), (.uint(2), .array([]))]))),
        .init("a protected header nested 16 levels deep",
              signed(protected: Fixture.goldenProtected + [(.uint(99), nested(15))])),
        .init("a non-minimal head on the protected bstr", Data([0xD2, 0x84, 0x59, 0x00, 0x46]) + golden[4..<400]),
    ]

    @Test(arguments: acceptedEnvelopes)
    func ignoresOtherLabelsAndTheUnprotectedMap(_ accepted: Case) throws {
        let envelope = try Attestation.envelope(accepted.bytes)
        #expect(envelope.keyID == Fixture.goldenKID)
        #expect(try Attestation.verify(envelope, key: Fixture.idpPublicKey, now: Self.later).issuedAt == 1_760_000_000)
    }

    // MARK: The signature

    private static let signatureRefusals: [Case] = {
        var lastByte = Self.golden
        lastByte[399] ^= 0x01
        var payloadByte = Self.golden
        payloadByte[333] ^= 0x01
        var kidByte = Self.golden
        kidByte[73] = UInt8(ascii: "2")
        let other = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x0B, count: 32))
        return [
            .init("the last byte flipped", lastByte),
            .init("a payload byte flipped", payloadByte),
            .init("the kid changed", kidByte),
            .init("a signature by another key", Fixture.mintAttestation(signer: other)),
            .init("a bad payload signed by another key", Fixture.mintAttestation(
                claims: .map([(.uint(1), .text("https://identity.arkavo.net"))]), signer: other)),
            .init("the signature of another attestation", Fixture.mintAttestation(claims: .map(Fixture.goldenClaims("iat", .uint(1_760_000_001))))
                .prefix(336) + Self.golden[336..<400]),
        ]
    }()

    @Test(arguments: signatureRefusals)
    func refusesASignatureTheKeyDidNotMake(_ refusal: Case) throws {
        let envelope = try Attestation.envelope(refusal.bytes)
        #expect(throws: CatalogBundleError.attestationSignature) {
            try Attestation.verify(envelope, key: Fixture.idpPublicKey, now: Self.later)
        }
    }

    /// Pins the note on `verify`: authnz-rs does not normalize s, so its golden signature is high-S (s > n/2). It and its
    /// low-S twin (r, n − s) both verify, so a "low-S only" rule would refuse what the IdP really sends.
    @Test
    func aHighSSignatureStillVerifies() throws {
        let order = Fixture.hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
        let halfOrder = Fixture.hex("7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8")
        let s = Self.golden[368..<400]
        #expect(halfOrder.lexicographicallyPrecedes(s))
        let lowS = Self.subtract(s, from: order)
        #expect(lowS == Fixture.hex("1de57aad5975c0648cb6fbd4db4216a302c3918b0e6ebeed93794e7926e10ffa"))
        #expect(!halfOrder.lexicographicallyPrecedes(lowS))
        #expect(try Self.verify(Self.golden).issuedAt == 1_760_000_000)
        #expect(try Self.verify(Self.golden.prefix(368) + lowS).issuedAt == 1_760_000_000)
    }

    /// `a − b` for two equal-length big-endian numbers with `a ≥ b`.
    private static func subtract(_ b: Data, from a: Data) -> Data {
        var result = [UInt8](repeating: 0, count: a.count)
        var borrow = 0
        for (index, (x, y)) in zip(a, b).enumerated().reversed() {
            let difference = Int(x) - Int(y) - borrow
            borrow = difference < 0 ? 1 : 0
            result[index] = UInt8(difference + borrow * 256)
        }
        return Data(result)
    }

    @Test
    func theGoldenBytesDoNotVerifyUnderTheLiveKey() throws {
        let live = try P256.Signing.PublicKey(x963Representation: Fixture.livePublicKeyX963)
        #expect(throws: CatalogBundleError.attestationSignature) { try Self.verify(Self.golden, key: live) }
    }

    // MARK: The clock

    @Test
    func iatSixtySecondsAheadIsAcceptedAndSixtyOneIsNot() throws {
        #expect(try Self.verify(Self.golden, now: 1_759_999_940).issuedAt == 1_760_000_000)
        #expect(throws: CatalogBundleError.attestationFromFuture) { try Self.verify(Self.golden, now: 1_759_999_939) }
    }

    @Test
    func iatHasNoLowerBound() throws {
        #expect(try Self.verify(Self.golden, now: .max).issuedAt == 1_760_000_000)
        #expect(try Self.verify(Self.minted(Fixture.goldenClaims("iat", .uint(0)))).issuedAt == 0)
    }

    @Test
    func iatAtInt64MaxDoesNotOverflow() throws {
        let latest = Self.minted(Fixture.goldenClaims("iat", .uint(UInt64(Int64.max))))
        #expect(try Self.verify(latest, now: .max).issuedAt == .max)
        #expect(try Self.verify(latest, now: .max - 60).issuedAt == .max)
        #expect(throws: CatalogBundleError.attestationFromFuture) { try Self.verify(latest, now: .max - 61) }
        #expect(throws: CatalogBundleError.attestationFromFuture) { try Self.verify(Self.golden, now: .min) }
    }

    @Test
    func claimsAreCheckedBeforeTheClock() {
        let typ = Self.minted(Fixture.goldenClaims("typ", .text("cwt")))
        #expect(throws: CatalogBundleError.attestationClaims) { try Self.verify(typ, now: 0) }
    }

    // MARK: The claims

    private static let claimRefusals: [Case] = {
        let claims = Fixture.goldenClaims
        let subject = TestCBOR.text(Fixture.subject)
        let iss = TestCBOR.text("https://identity.arkavo.net")
        return [
            .init("an extra exp", minted(claims + [(.text("exp"), .uint(1_900_000_000))])),
            .init("exp in place of iat", minted(Fixture.goldenClaims(replacing: "iat", with: (.text("exp"), .uint(1_760_000_000))))),
            .init("a repeated sub", minted(claims + [(.text("sub"), subject)])),
            .init("sub twice in place of rpId", minted(Fixture.goldenClaims(replacing: "rpId", with: (.text("sub"), subject)))),
            .init("a missing iat", minted(Fixture.goldenClaims(replacing: "iat", with: nil))),
            .init("typ cwt", minted(Fixture.goldenClaims("typ", .text("cwt")))),
            .init("typ as bytes", minted(Fixture.goldenClaims("typ", .bytes(Array("arkavo-passkey-credential".utf8))))),
            .init("iss https://identity.arkavo.net/", minted(Fixture.goldenClaims("iss", .text("https://identity.arkavo.net/")))),
            .init("iss in upper case", minted(Fixture.goldenClaims("iss", .text("https://IDENTITY.arkavo.net")))),
            .init("rpId arkavo.net", minted(Fixture.goldenClaims("rpId", .text("arkavo.net")))),
            .init("rpId as the issuer", minted(Fixture.goldenClaims("rpId", iss))),
            .init("an empty sub", minted(Fixture.goldenClaims("sub", .text("")))),
            .init("sub as bytes", minted(Fixture.goldenClaims("sub", .bytes(Array(Fixture.subject.utf8))))),
            .init("an empty credentialId", minted(Fixture.goldenClaims("credentialId", .bytes([])))),
            .init("credentialId as text", minted(Fixture.goldenClaims("credentialId", .text("AAECAwQFBgcICQoLDA0ODw")))),
            .init("iat −1", minted(Fixture.goldenClaims("iat", .nint(0)))),
            .init("iat Int64.max + 1", minted(Fixture.goldenClaims("iat", .uint(UInt64(Int64.max) + 1)))),
            .init("iat as text", minted(Fixture.goldenClaims("iat", .text("1760000000")))),
            .init("iat as a float", minted(Fixture.goldenClaims("iat", .raw([0xFA, 0x4E, 0xD1, 0xCE, 0xF0])))),
            .init("publicKey crv 2", minted(Fixture.goldenClaims("publicKey", Fixture.coseKey(crv: .uint(2))))),
            .init("publicKey kty 3", minted(Fixture.goldenClaims("publicKey", Fixture.coseKey(kty: .uint(3))))),
            .init("publicKey x of 31 bytes", minted(Fixture.goldenClaims("publicKey", Fixture.coseKey(x: Fixture.credentialX.prefix(31))))),
            .init("publicKey y of 33 bytes", minted(Fixture.goldenClaims("publicKey", Fixture.coseKey(y: Fixture.credentialY + Data([0]))))),
            .init("publicKey x as text", minted(Fixture.goldenClaims("publicKey", .map([
                (.uint(1), .uint(2)), (.nint(0), .uint(1)), (.nint(1), .text(String(repeating: "x", count: 32))),
                (.nint(2), .bytes(Array(Fixture.credentialY)))])))),
            .init("publicKey without y", minted(Fixture.goldenClaims("publicKey", .map([
                (.uint(1), .uint(2)), (.nint(0), .uint(1)), (.nint(1), .bytes(Array(Fixture.credentialX)))])))),
            .init("publicKey with x twice", minted(Fixture.goldenClaims("publicKey", Fixture.coseKey(
                extra: [(.nint(1), .bytes(Array(Fixture.credentialX)))])))),
            .init("publicKey with kty twice", minted(Fixture.goldenClaims("publicKey", Fixture.coseKey(
                extra: [(.uint(1), .uint(2))])))),
            .init("an off-curve key", minted(Fixture.goldenClaims("publicKey", Fixture.coseKey(
                x: Data(repeating: 0, count: 32), y: Data(repeating: 0, count: 32))))),
            .init("a key with y's last bit flipped", minted(Fixture.goldenClaims("publicKey", Fixture.coseKey(
                y: Data(Fixture.credentialY.dropLast()) + Data([Fixture.credentialY.last! ^ 0x01]))))),
            .init("publicKey as X9.63 bytes", minted(Fixture.goldenClaims("publicKey", .bytes(Array(
                Fixture.credentialPrivateKey.publicKey.x963Representation))))),
            .init("a CWT-shaped {1: iss} payload", minted([(.uint(1), iss)])),
            .init("a uint key in place of typ", minted(Fixture.goldenClaims(
                replacing: "typ", with: (.uint(1), .text("arkavo-passkey-credential"))))),
            .init("a key spelt with the Kelvin sign", minted(Fixture.goldenClaims(
                replacing: "publicKey", with: (.text("public\u{212A}ey"), Fixture.coseKey())))),
            .init("an empty map", minted([])),
            .init("an array payload", Fixture.mintAttestation(claims: .array([.text("typ")]))),
            .init("a payload with a trailing byte", Fixture.signAttestation(
                protected: TestCBOR.map(Fixture.goldenProtected).data,
                payload: TestCBOR.map(claims).data + Data([0x00]))),
            .init("an empty payload", Fixture.signAttestation(
                protected: TestCBOR.map(Fixture.goldenProtected).data, payload: Data())),
            .init("a sub with a leading BOM", minted(Fixture.goldenClaims("sub", .text("\u{FEFF}" + Fixture.subject)))),
            .init("a map head declaring 2^64 − 1 pairs", Fixture.signAttestation(
                protected: TestCBOR.map(Fixture.goldenProtected).data,
                payload: Data([0xBB] + [UInt8](repeating: 0xFF, count: 8)) + TestCBOR.map(claims).data.dropFirst())),
            .init("a map head declaring 8 pairs over 7", Fixture.signAttestation(
                protected: TestCBOR.map(Fixture.goldenProtected).data,
                payload: Data([0xA8]) + TestCBOR.map(claims).data.dropFirst())),
        ]
    }()

    @Test(arguments: claimRefusals)
    func refusesClaimsThatAreNotAPasskeyCredential(_ refusal: Case) throws {
        let envelope = try Attestation.envelope(refusal.bytes)
        #expect(throws: CatalogBundleError.attestationClaims) {
            try Attestation.verify(envelope, key: Fixture.idpPublicKey, now: Self.later)
        }
    }

    private static let acceptedClaims: [Case] = [
        .init("claims in another order", minted(Fixture.goldenClaims.reversed())),
        .init("other COSE_Key labels", minted(Fixture.goldenClaims("publicKey", Fixture.coseKey(extra: [
            (.uint(3), .nint(6)), (.uint(2), .bytes(Array("k".utf8))), (.text("x"), .uint(1)), (.nint(9), .uint(0))])))),
        .init("COSE_Key labels in another order", minted(Fixture.goldenClaims("publicKey", .map([
            (.nint(2), .bytes(Array(Fixture.credentialY))), (.nint(1), .bytes(Array(Fixture.credentialX))), (.nint(0), .uint(1)),
            (.uint(1), .uint(2))])))),
    ]

    @Test(arguments: acceptedClaims)
    func acceptsTheContractShapeInAnyOrder(_ accepted: Case) throws {
        let credential = try Self.verify(accepted.bytes)
        #expect(Array(credential.subject.utf8) == Array(Fixture.subject.utf8))
        #expect(credential.credentialID == Fixture.credentialID)
        #expect(credential.issuedAt == 1_760_000_000)
        #expect(credential.publicKey.x963Representation == Fixture.credentialPrivateKey.publicKey.x963Representation)
    }

    @Test
    func theSubjectAndCredentialIDAreReturnedAsAttested() throws {
        let other = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x0B, count: 32)).publicKey
        let x963 = other.x963Representation
        let claims = Fixture.goldenClaims("sub", .text("5c1f0e7a-2b8d-4c0f-9a51-3f2b6d8e4a10"))
            .map { pair -> (TestCBOR, TestCBOR) in
                guard case .text(let key) = pair.0 else { return pair }
                switch key {
                case "credentialId": return (pair.0, .bytes([UInt8](repeating: 0x0B, count: 16)))
                case "publicKey": return (pair.0, Fixture.coseKey(x: x963[1..<33], y: x963[33..<65]))
                default: return pair
                }
            }
        let credential = try Self.verify(Self.minted(claims))
        #expect(Array(credential.subject.utf8) == Array("5c1f0e7a-2b8d-4c0f-9a51-3f2b6d8e4a10".utf8))
        #expect(credential.credentialID == Data(repeating: 0x0B, count: 16))
        #expect(credential.publicKey.x963Representation == x963)
    }
}
