import CryptoKit
import Foundation
import Testing
@testable import ArkavoCatalog

/// The WebAuthn assertion over the pointer bytes: the node's `verify_assertion` rules, checked
/// against the attested credential key. Every case starts from the pointer `P7`, the client data `C7` and the authenticator
/// data `A`, signed by the credential key `0x07` at run time, and breaks one thing. Signatures are random, so none is compared.
struct WebAuthnAssertionTests {
    private typealias Fixture = CatalogV2Fixture
    private typealias Assertion = WebAuthnAssertion

    private static let key = Fixture.credentialPrivateKey.publicKey
    private static let otherKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x0A, count: 32))

    struct Case: Sendable, CustomTestStringConvertible {
        let label: String
        let pointer: Data
        let authenticatorData: Data
        let clientData: Data
        /// The signature, or nil to sign `authenticatorData ‖ SHA256(clientData)` with the credential key.
        let signature: Data?
        init(_ label: String, pointer: Data = Fixture.pointer, authenticatorData: Data = Fixture.authenticatorData,
             clientData: Data = Fixture.clientData, signature: Data? = nil) {
            self.label = label
            self.pointer = pointer
            self.authenticatorData = authenticatorData
            self.clientData = clientData
            self.signature = signature
        }
        var testDescription: String { label }
    }

    private static func verify(_ test: Case) throws {
        let signature = test.signature ?? Fixture.assertionSignature(
            authenticatorData: test.authenticatorData, clientData: test.clientData)
        try Assertion.verify(pointer: test.pointer, authenticatorData: test.authenticatorData,
                             clientDataJSON: test.clientData, signature: signature, key: key)
    }

    /// `C7` with its members replaced by raw JSON text, in the order type, challenge, origin, then `extra`.
    private static func clientData(type: String = #""webauthn.get""#, challenge: String? = nil,
                                   origin: String = #""https://identity.arkavo.net""#, extra: String = "") -> Data {
        let challenge = challenge ?? #""\#(Fixture.pointerChallenge)""#
        return Data(#"{"type":\#(type),"challenge":\#(challenge),"origin":\#(origin)\#(extra)}"#.utf8)
    }

    private static func authenticatorData(replacing offset: Int, with byte: UInt8) -> Data {
        var data = Fixture.authenticatorData
        data[offset] = byte
        return data
    }

    private static func expect(_ expected: CatalogBundleError, for test: Case) {
        #expect(throws: expected) { try verify(test) }
    }

    // MARK: Accepted

    @Test
    func theConstantsAreTheContractValues() {
        #expect(Assertion.origin == "https://identity.arkavo.net")
        #expect(Assertion.relyingPartyIDHash == Fixture.authenticatorData.prefix(32))
        #expect(Assertion.relyingPartyIDHash == Fixture.hex(
            "496676630158193beba7c3e062dd5fe42f2385cd2986aee21cbe3258646180c8"))
    }

    @Test
    func aValidAssertionVerifies() throws {
        try Self.verify(Case("P7, C7 and A"))
    }

    @Test
    func theFixtureBundleBuilderSignsAValidAssertion() throws {
        let bundle = try CatalogBundle.decode(Fixture.bundle())
        try Assertion.verify(pointer: bundle.pointer, authenticatorData: bundle.authenticatorData,
                             clientDataJSON: bundle.clientDataJSON, signature: bundle.signature, key: Self.key)
    }

    private static let accepted: [Case] = [
        .init("crossOrigin false", clientData: clientData(extra: #","crossOrigin":false"#)),
        .init("crossOrigin null", clientData: clientData(extra: #","crossOrigin":null"#)),
        .init("crossOrigin the text true", clientData: clientData(extra: #","crossOrigin":"true""#)),
        .init("an extra member", clientData: clientData(extra: #","other_keys_can_be_added_here":"x""#)),
        .init("whitespace around the object",
              clientData: Data(" \n".utf8) + clientData() + Data("\t ".utf8)),
        .init("members in another order", clientData: Data(
            #"{"origin":"https://identity.arkavo.net","challenge":"\#(Fixture.pointerChallenge)","type":"webauthn.get"}"#.utf8)),
        .init("A with A0 appended", authenticatorData: Fixture.authenticatorData + Data([0xA0])),
        .init("A with extension data appended",
              authenticatorData: Fixture.authenticatorData + Data(repeating: 0x5A, count: 64)),
        .init("a counter of 00000005", authenticatorData: {
            var data = Fixture.authenticatorData
            data.replaceSubrange(33..<37, with: [0x00, 0x00, 0x00, 0x05])
            return data
        }()),
        .init("a counter of ffffffff", authenticatorData: {
            var data = Fixture.authenticatorData
            data.replaceSubrange(33..<37, with: [0xFF, 0xFF, 0xFF, 0xFF])
            return data
        }()),
        .init("flags 0x45 (UP, UV and attested-credential data)", authenticatorData: authenticatorData(replacing: 32, with: 0x45)),
        .init("flags 0x1D (UP, UV, backup eligible and state)", authenticatorData: authenticatorData(replacing: 32, with: 0x1D)),
    ]

    @Test(arguments: accepted)
    func anAcceptedVariantVerifies(_ test: Case) throws {
        try Self.verify(test)
    }

    @Test
    func theSignedPointerBytesAreHashedAsReceived() throws {
        // The challenge is over the pointer exactly as received, so whitespace the node kept is whitespace the reader hashes.
        let pointer = Fixture.pointer + Data(" \n".utf8)
        let challenge = Base64URL.encode(Data(SHA256.hash(data: pointer)))
        try Self.verify(Case("a pointer with trailing whitespace", pointer: pointer,
                             clientData: Self.clientData(challenge: #""\#(challenge)""#)))
    }

    // MARK: clientDataJSON

    private static let typeRefusals: [Case] = [
        .init("webauthn.create", clientData: clientData(type: #""webauthn.create""#)),
        .init("type with another case", clientData: clientData(type: #""WebAuthn.get""#)),
        .init("type with a trailing space", clientData: clientData(type: #""webauthn.get ""#)),
        .init("type a number", clientData: clientData(type: "1")),
        .init("type null", clientData: clientData(type: "null")),
        .init("type missing", clientData: Data(
            #"{"challenge":"\#(Fixture.pointerChallenge)","origin":"https://identity.arkavo.net"}"#.utf8)),
        .init("not JSON", clientData: Data("not json".utf8)),
        .init("an array", clientData: Data("[]".utf8)),
        .init("a string", clientData: Data(#""webauthn.get""#.utf8)),
        .init("a JSON text with a trailing 00", clientData: Fixture.clientData + Data([0x00])),
        .init("a JSON text with trailing text", clientData: Fixture.clientData + Data("x".utf8)),
        .init("a byte-order mark", clientData: Data([0xEF, 0xBB, 0xBF]) + Fixture.clientData),
        .init("a repeated type", clientData: clientData(extra: #","type":"webauthn.get""#)),
        .init("a repeated type, the first one wrong", clientData: Data(
            #"{"type":"webauthn.create","type":"webauthn.get","challenge":"\#(Fixture.pointerChallenge)","origin":"https://identity.arkavo.net"}"#.utf8)),
        .init("an object that is well formed but for a non-UTF-8 byte inside a string", clientData:
            Data(#"{"type":"webauthn.get","challenge":"\#(Fixture.pointerChallenge)","origin":"https://identity.arkavo.net","x":""#.utf8)
            + Data([0xFF]) + Data(#""}"#.utf8)),
    ]

    @Test(arguments: typeRefusals)
    func aBadClientDataTypeIsRefused(_ test: Case) {
        Self.expect(.clientDataType, for: test)
    }

    private static let seq8Pointer = Data(Fixture.pointerText.replacingOccurrences(of: #""seq":7"#, with: #""seq":8"#).utf8)

    /// A pointer whose SHA-256 challenge needs `-` or `_`, so the standard alphabet spells it differently.
    private static let urlSafeSensitive: (pointer: Data, challenge: String) = {
        for index in 0..<10_000 {
            let pointer = Data("pointer \(index)".utf8)
            let challenge = Base64URL.encode(Data(SHA256.hash(data: pointer)))
            if challenge.contains("-") || challenge.contains("_") { return (pointer, challenge) }
        }
        fatalError("no pointer found")
    }()

    private static let challengeRefusals: [Case] = [
        .init("the challenge of the seq 8 pointer", clientData: clientData(
            challenge: #""\#(Base64URL.encode(Data(SHA256.hash(data: seq8Pointer))))""#)),
        .init("the padded challenge", clientData: clientData(challenge: #""\#(Fixture.pointerChallenge)=""#)),
        .init("a non-canonical last character", clientData: clientData(
            challenge: #""\#(Fixture.pointerChallenge.dropLast())x""#)),
        .init("the standard alphabet", pointer: urlSafeSensitive.pointer, clientData: clientData(
            challenge: #""\#(urlSafeSensitive.challenge.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))""#)),
        .init("a challenge that is a number", clientData: clientData(challenge: "123")),
        .init("a challenge that is null", clientData: clientData(challenge: "null")),
        .init("a challenge that is an array of the bytes", clientData: clientData(challenge: "[1,2,3]")),
        .init("an empty challenge", clientData: clientData(challenge: #""""#)),
        .init("a challenge of 42 characters", clientData: clientData(
            challenge: #""\#(Fixture.pointerChallenge.dropLast())""#)),
        .init("the challenge in upper case", clientData: clientData(
            challenge: #""\#(Fixture.pointerChallenge.uppercased())""#)),
        .init("the challenge missing", clientData: Data(
            #"{"type":"webauthn.get","origin":"https://identity.arkavo.net"}"#.utf8)),
        .init("a challenge for a pointer that differs by one byte", pointer: Fixture.pointer + Data(" ".utf8)),
    ]

    @Test(arguments: challengeRefusals)
    func aBadChallengeIsRefused(_ test: Case) {
        Self.expect(.challenge, for: test)
    }

    @Test
    func theStandardAlphabetFixtureReallyDiffers() {
        #expect(Self.urlSafeSensitive.challenge.contains("-") || Self.urlSafeSensitive.challenge.contains("_"))
        // The URL-safe spelling of the same pointer verifies, so the refusal above is the alphabet and nothing else.
        #expect(throws: Never.self) {
            try Self.verify(Case("url-safe", pointer: Self.urlSafeSensitive.pointer, clientData: Self.clientData(
                challenge: #""\#(Self.urlSafeSensitive.challenge)""#)))
        }
    }

    private static let originRefusals: [Case] = [
        .init("https://evil.example", clientData: clientData(origin: #""https://evil.example""#)),
        .init("the identity origin with port 443", clientData: clientData(origin: #""https://identity.arkavo.net:443""#)),
        .init("the identity origin over http", clientData: clientData(origin: #""http://identity.arkavo.net""#)),
        .init("the identity origin with a trailing slash", clientData: clientData(origin: #""https://identity.arkavo.net/""#)),
        .init("the identity origin in upper case", clientData: clientData(origin: #""HTTPS://IDENTITY.ARKAVO.NET""#)),
        .init("a subdomain", clientData: clientData(origin: #""https://a.identity.arkavo.net""#)),
        .init("the bare host", clientData: clientData(origin: #""identity.arkavo.net""#)),
        .init("an empty origin", clientData: clientData(origin: #""""#)),
        .init("an origin that is a number", clientData: clientData(origin: "1")),
        .init("an origin that is null", clientData: clientData(origin: "null")),
        .init("the origin missing", clientData: Data(
            #"{"type":"webauthn.get","challenge":"\#(Fixture.pointerChallenge)"}"#.utf8)),
    ]

    @Test(arguments: originRefusals)
    func aBadOriginIsRefused(_ test: Case) {
        Self.expect(.origin, for: test)
    }

    @Test
    func crossOriginTrueIsRefused() {
        Self.expect(.crossOrigin, for: Case("crossOrigin true", clientData: Self.clientData(extra: #","crossOrigin":true"#)))
        Self.expect(.crossOrigin, for: Case("crossOrigin true first", clientData: Data(
            #"{"crossOrigin":true,"type":"webauthn.get","challenge":"\#(Fixture.pointerChallenge)","origin":"https://identity.arkavo.net"}"#.utf8)))
    }

    // MARK: authenticatorData

    private static let authenticatorDataRefusals: [Case] = [
        .init("36 bytes", authenticatorData: Fixture.authenticatorData.dropLast()),
        .init("33 bytes", authenticatorData: Fixture.authenticatorData.prefix(33)),
        .init("32 bytes", authenticatorData: Fixture.authenticatorData.prefix(32)),
        .init("no bytes", authenticatorData: Data()),
    ]

    @Test(arguments: authenticatorDataRefusals)
    func shortAuthenticatorDataIsRefused(_ test: Case) {
        Self.expect(.authenticatorData, for: test)
    }

    private static let rpIDHashRefusals: [Case] = [
        .init("byte 0 flipped", authenticatorData: authenticatorData(replacing: 0, with: Fixture.authenticatorData[0] ^ 0x01)),
        .init("byte 31 flipped", authenticatorData: authenticatorData(replacing: 31, with: Fixture.authenticatorData[31] ^ 0x80)),
        .init("SHA-256 of arkavo.net", authenticatorData: Data(SHA256.hash(data: Data("arkavo.net".utf8)))
            + Fixture.authenticatorData.dropFirst(32)),
        .init("SHA-256 of https://identity.arkavo.net", authenticatorData: Data(
            SHA256.hash(data: Data("https://identity.arkavo.net".utf8))) + Fixture.authenticatorData.dropFirst(32)),
        .init("an all-zero hash", authenticatorData: Data(repeating: 0, count: 32) + Fixture.authenticatorData.dropFirst(32)),
    ]

    @Test(arguments: rpIDHashRefusals)
    func aWrongRelyingPartyHashIsRefused(_ test: Case) {
        Self.expect(.rpIDHash, for: test)
    }

    @Test
    func theFlagsAreCheckedUserPresenceFirst() {
        Self.expect(.userPresence, for: Case("flags 0x04", authenticatorData: Self.authenticatorData(replacing: 32, with: 0x04)))
        Self.expect(.userVerification, for: Case("flags 0x01", authenticatorData: Self.authenticatorData(replacing: 32, with: 0x01)))
        Self.expect(.userPresence, for: Case("flags 0x00", authenticatorData: Self.authenticatorData(replacing: 32, with: 0x00)))
        Self.expect(.userPresence, for: Case("flags 0xFA", authenticatorData: Self.authenticatorData(replacing: 32, with: 0xFA)))
        Self.expect(.userVerification, for: Case("flags 0xFB", authenticatorData: Self.authenticatorData(replacing: 32, with: 0xFB)))
    }

    // MARK: The signature

    /// A DER signature of the valid message by the credential key, and what to do to it.
    private static func derSignature() -> P256.Signing.ECDSASignature {
        try! P256.Signing.ECDSASignature(derRepresentation: Fixture.assertionSignature())
    }

    private static let signatureRefusals: [Case] = [
        .init("the 64-byte raw signature", signature: derSignature().rawRepresentation),
        .init("DER with a trailing 00", signature: Fixture.assertionSignature() + Data([0x00])),
        .init("DER with a trailing 30 00", signature: Fixture.assertionSignature() + Data([0x30, 0x00])),
        .init("a signature by 0x0A", signature: Fixture.assertionSignature(key: otherKey)),
        .init("a signature over another clientDataJSON", signature: Fixture.assertionSignature(
            clientData: clientData(extra: #","x":1"#))),
        .init("a signature over another authenticatorData", signature: Fixture.assertionSignature(
            authenticatorData: Fixture.authenticatorData + Data([0x00]))),
        .init("a signature over the clientDataJSON alone", signature: (try! Fixture.credentialPrivateKey.signature(
            for: Fixture.clientData)).derRepresentation),
        .init("a signature over the pointer", signature: (try! Fixture.credentialPrivateKey.signature(
            for: Fixture.pointer)).derRepresentation),
        .init("an empty signature", signature: Data()),
        .init("one byte of 30", signature: Data([0x30])),
        .init("the DER with its last byte cut", signature: Fixture.assertionSignature().dropLast()),
        .init("random bytes", signature: Data(repeating: 0xAB, count: 70)),
    ]

    @Test(arguments: signatureRefusals)
    func aBadSignatureIsRefused(_ test: Case) {
        Self.expect(.assertionSignature, for: test)
    }

    @Test
    func aSignatureThatIsNotInCanonicalDERIsRefused() throws {
        // A valid signature re-spelled with a long-form length (0x81 nn) or a padded integer is not the node's canonical DER.
        let der = Fixture.assertionSignature()
        #expect(der[0] == 0x30)
        let longForm = Data([0x30, 0x81]) + der.dropFirst(1)
        Self.expect(.assertionSignature, for: Case("a long-form length", signature: longForm))
        let paddedR = Data([0x30, der[1] + 1, 0x02, der[3] + 1, 0x00]) + der[4...]
        Self.expect(.assertionSignature, for: Case("a padded r", signature: paddedR))
        Self.expect(.assertionSignature, for: Case("a trailing byte after the sequence", signature: der + Data([0x00])))
    }

    /// CryptoKit's `ECDSASignature(derRepresentation:)` is strict: it refuses trailing bytes, a long-form length, a padded
    /// integer and the raw form. `WebAuthnAssertion.verify` still compares the parsed signature's re-encoding with the
    /// input, as a hedge. If a later CryptoKit turned lenient, this fails first, and that comparison is what would then
    /// keep refusing non-canonical DER.
    @Test
    func cryptoKitRefusesNonCanonicalDERItself() throws {
        let der = Fixture.assertionSignature()
        #expect(throws: (any Error).self) { try P256.Signing.ECDSASignature(derRepresentation: der + Data([0x00])) }
        #expect(throws: (any Error).self) { try P256.Signing.ECDSASignature(derRepresentation: der + Data([0x30, 0x00])) }
        #expect(throws: (any Error).self) { try P256.Signing.ECDSASignature(derRepresentation: Data([0x30, 0x81]) + der.dropFirst()) }
        #expect(throws: (any Error).self) {
            try P256.Signing.ECDSASignature(derRepresentation: Data([0x30, der[1] + 1, 0x02, der[3] + 1, 0x00]) + der[4...])
        }
        let raw = try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation
        #expect(throws: (any Error).self) { try P256.Signing.ECDSASignature(derRepresentation: raw) }
    }

    // MARK: Order

    @Test
    func theChecksRunInTheContractsOrder() {
        let badType = Self.clientData(type: #""webauthn.create""#, challenge: "1", origin: #""https://evil.example""#,
                                      extra: #","crossOrigin":true"#)
        let shortAuthData = Fixture.authenticatorData.dropLast()
        // type before challenge, origin and crossOrigin.
        Self.expect(.clientDataType, for: Case("everything wrong", authenticatorData: shortAuthData, clientData: badType,
                                              signature: Data()))
        Self.expect(.challenge, for: Case("challenge before origin and crossOrigin", authenticatorData: shortAuthData,
                                         clientData: Self.clientData(challenge: "1", origin: #""https://evil.example""#,
                                                                    extra: #","crossOrigin":true"#), signature: Data()))
        Self.expect(.origin, for: Case("origin before crossOrigin", authenticatorData: shortAuthData,
                                      clientData: Self.clientData(origin: #""https://evil.example""#,
                                                                 extra: #","crossOrigin":true"#), signature: Data()))
        // The client data is checked before the authenticator data, and that before the signature.
        Self.expect(.crossOrigin, for: Case("crossOrigin before authenticatorData", authenticatorData: shortAuthData,
                                           clientData: Self.clientData(extra: #","crossOrigin":true"#), signature: Data()))
        Self.expect(.authenticatorData, for: Case("length before the hash", authenticatorData: shortAuthData, signature: Data()))
        let wrongHashNoFlags = Data(repeating: 0, count: 32) + Data([0x00, 0, 0, 0, 0])
        Self.expect(.rpIDHash, for: Case("the hash before the flags", authenticatorData: wrongHashNoFlags, signature: Data()))
        Self.expect(.userPresence, for: Case("user presence before the signature",
                                            authenticatorData: Self.authenticatorData(replacing: 32, with: 0x00), signature: Data()))
        Self.expect(.userVerification, for: Case("user verification before the signature",
                                                authenticatorData: Self.authenticatorData(replacing: 32, with: 0x01), signature: Data()))
    }
}
