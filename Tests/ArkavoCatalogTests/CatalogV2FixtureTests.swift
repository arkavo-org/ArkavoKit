import CryptoKit
import Foundation
import Testing
@testable import ArkavoCatalog

/// The catalog v2 fixtures agree with each other, so a typo in one cannot hide behind another.
struct CatalogV2FixtureTests {
    private typealias Fixture = CatalogV2Fixture

    @Test
    func pointerIsP7() {
        #expect(Fixture.pointer.count == 224)
        #expect(Data(SHA256.hash(data: Fixture.pointer))
            == Fixture.hex("62bd64a0aa7db83dab5619669da769f0fbafc21b9a35186b184d8580b9b90d3c"))
    }

    @Test
    func thePointerBuilderReproducesP7() {
        #expect(Fixture.makePointer() == Fixture.pointer)
    }

    @Test
    func theCredentialAttestationMinterReproducesTheGoldenEncoding() {
        #expect(Fixture.mintCredentialAttestation().prefix(336) == Fixture.goldenAttestation.prefix(336))
    }

    @Test
    func pointerChallengeIsTheBase64URLOfP7sSHA256() {
        #expect(Base64URL.encode(Data(SHA256.hash(data: Fixture.pointer))) == Fixture.pointerChallenge)
        #expect(Fixture.clientDataText.contains(#""challenge":"\#(Fixture.pointerChallenge)""#))
    }

    /// The library has no BLAKE3, so only the size P7 names is checked here; `documentHash` is the contract's value.
    @Test
    func documentIsTheSizeP7Names() {
        #expect(Fixture.document.count == 97)
        #expect(Fixture.pointerText.contains(#""catalogSize":\#(Fixture.document.count)"#))
        #expect(Fixture.pointerText.contains(#""catalogHash":"\#(Fixture.documentHash)""#))
    }

    @Test
    func idpPublicKeyIsScalar0x42() throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        #expect(key.publicKey.x963Representation == Fixture.idpPublicKeyX963)
        #expect(Fixture.idpPublicKey.x963Representation == Fixture.idpPublicKeyX963)
    }

    @Test
    func credentialKeyIsScalar0x07() {
        #expect(Fixture.credentialPrivateKey.publicKey.x963Representation
            == Data([0x04]) + Fixture.credentialX + Fixture.credentialY)
    }

    @Test
    func liveKeyIsTheLiveSetsOnlyKey() throws {
        let set = Fixture.liveKeySet
        #expect(set.count == 113)
        #expect(set.range(of: Data([0x58, 0x20]) + Fixture.liveKID) != nil)
        #expect(set.range(of: Data([0x21, 0x58, 0x20]) + Fixture.livePublicKeyX963[1..<33]) != nil)
        #expect(set.range(of: Data([0x22, 0x58, 0x20]) + Fixture.livePublicKeyX963[33..<65]) != nil)
        #expect(try P256.Signing.PublicKey(x963Representation: Fixture.livePublicKeyX963).x963Representation.count == 65)
    }

    @Test
    func authenticatorDataBeginsWithTheRPIDHash() {
        #expect(Fixture.authenticatorData.count == 37)
        #expect(Fixture.authenticatorData.prefix(32) == Data(SHA256.hash(data: Data("identity.arkavo.net".utf8))))
        #expect(Fixture.authenticatorData[32] == 0x05)
    }

    @Test
    func testCBORUsesShortestFormHeads() {
        #expect(TestCBOR.uint(23).data == Data([0x17]))
        #expect(TestCBOR.uint(24).data == Data([0x18, 0x18]))
        #expect(TestCBOR.nint(6).data == Data([0x26]))
        #expect(TestCBOR.uint(1_760_000_000).data == Fixture.hex("1a68e77800"))
        #expect(TestCBOR.bytes([UInt8](repeating: 0, count: 256)).data.prefix(3) == Data([0x59, 0x01, 0x00]))
        #expect(TestCBOR.uint(UInt64.max).data == Data([0x1B] + [UInt8](repeating: 0xFF, count: 8)))
        #expect(TestCBOR.tag(18, .array([])).data == Data([0xD2, 0x80]))
    }
}
