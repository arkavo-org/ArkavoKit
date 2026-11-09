import CryptoKit
import XCTest
@testable import ArkavoSocial

/// The owner-KAS vault (ArkavoKit#73, arkavo-ios owner-KAS design §4.7): a blob sealed with AES-256-GCM under
/// HKDF-SHA-256(PRF output, a random 32-byte salt, "arkavo.owner-kas.vault/v1"), bound to its vault ID, owner
/// subject, KAS key ID and algorithm.
final class OwnerKASVaultTests: XCTestCase {
    private static let relyingPartyID = "identity.example.test"
    private static let credentialID = Data([0xC0, 0xFF, 0xEE])
    private static let input = Data(repeating: 0x11, count: 32)
    private static let prfBytes = Data(repeating: 0x42, count: 32)
    private static let binding = OwnerKASVaultBinding(
        vaultID: "01JC9Z3M6V0F7Q8R2S4T6W8Y0A",
        ownerSubject: "0a1b2c3d-0000-4000-8000-000000000001",
        kasKeyID: "kas-1",
        algorithm: "ec:secp256r1"
    )
    private static let secret = Data("owner-kas vault vector".utf8)

    private func prf(
        key: Data = prfBytes,
        credentialID: Data = credentialID,
        input: Data = input,
        relyingPartyID: String = relyingPartyID
    ) -> PasskeyPRFOutput {
        PasskeyPRFOutput(
            credentialID: credentialID,
            relyingPartyID: relyingPartyID,
            input: input,
            userID: nil,
            key: SymmetricKey(data: key)
        )
    }

    private func assertVaultError<T>(
        _ expected: OwnerKASVaultError,
        _ call: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try call(), file: file, line: line) { error in
            XCTAssertEqual(error as? OwnerKASVaultError, expected, file: file, line: line)
        }
    }

    // MARK: - Seal and open

    func testSealThenOpenGivesTheSecretBack() throws {
        let vault = try OwnerKASVault.seal(Self.secret, with: prf(), binding: Self.binding)

        XCTAssertEqual(try vault.open(with: prf(), binding: Self.binding), Self.secret)
    }

    func testTheVaultRecordsThePasskeyAndItsRandoms() throws {
        let vault = try OwnerKASVault.seal(Self.secret, with: prf(), binding: Self.binding)

        XCTAssertEqual(vault.version, 1)
        XCTAssertEqual(vault.relyingPartyID, Self.relyingPartyID)
        XCTAssertEqual(vault.credentialID, Self.credentialID)
        XCTAssertEqual(vault.prfInput, Self.input)
        XCTAssertEqual(vault.salt.count, 32)
        XCTAssertEqual(vault.nonce.count, 12)
        // Ciphertext and the 16-byte tag.
        XCTAssertEqual(vault.blob.count, Self.secret.count + 16)
        XCTAssertNil(vault.blob.range(of: Self.secret))
    }

    func testEachSealUsesAFreshSaltAndNonce() throws {
        let first = try OwnerKASVault.seal(Self.secret, with: prf(), binding: Self.binding)
        let second = try OwnerKASVault.seal(Self.secret, with: prf(), binding: Self.binding)

        XCTAssertNotEqual(first.salt, second.salt)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.blob, second.blob)
    }

    func testAnotherPRFOutputCannotOpen() throws {
        let vault = try OwnerKASVault.seal(Self.secret, with: prf(), binding: Self.binding)

        assertVaultError(.cannotOpen) {
            try vault.open(with: prf(key: Data(repeating: 0x43, count: 32)), binding: Self.binding)
        }
    }

    func testEveryBindingFieldIsAuthenticated() throws {
        let vault = try OwnerKASVault.seal(Self.secret, with: prf(), binding: Self.binding)
        let b = Self.binding
        let others = [
            OwnerKASVaultBinding(vaultID: "other", ownerSubject: b.ownerSubject, kasKeyID: b.kasKeyID, algorithm: b.algorithm),
            OwnerKASVaultBinding(vaultID: b.vaultID, ownerSubject: "other", kasKeyID: b.kasKeyID, algorithm: b.algorithm),
            OwnerKASVaultBinding(vaultID: b.vaultID, ownerSubject: b.ownerSubject, kasKeyID: "other", algorithm: b.algorithm),
            OwnerKASVaultBinding(vaultID: b.vaultID, ownerSubject: b.ownerSubject, kasKeyID: b.kasKeyID, algorithm: "other"),
        ]

        for other in others {
            assertVaultError(.cannotOpen) { try vault.open(with: prf(), binding: other) }
        }
    }

    func testFieldsCannotShiftBetweenBindingParts() throws {
        // Without length prefixes these two would authenticate the same bytes.
        let vault = try OwnerKASVault.seal(
            Self.secret,
            with: prf(),
            binding: OwnerKASVaultBinding(vaultID: "ab", ownerSubject: "c", kasKeyID: "k", algorithm: "a")
        )

        assertVaultError(.cannotOpen) {
            try vault.open(
                with: prf(),
                binding: OwnerKASVaultBinding(vaultID: "a", ownerSubject: "bc", kasKeyID: "k", algorithm: "a")
            )
        }
    }

    func testATamperedVaultCannotOpen() throws {
        let vault = try OwnerKASVault.seal(Self.secret, with: prf(), binding: Self.binding)
        func flipped(_ data: Data) -> Data {
            var data = data
            data[data.startIndex] ^= 0x01
            return data
        }

        var blob = vault
        blob.blob = flipped(vault.blob)
        var salt = vault
        salt.salt = flipped(vault.salt)
        var nonce = vault
        nonce.nonce = flipped(vault.nonce)

        for tampered in [blob, salt, nonce] {
            assertVaultError(.cannotOpen) { try tampered.open(with: prf(), binding: Self.binding) }
        }
    }

    func testAnotherPasskeyIsRefusedBeforeDecrypting() throws {
        let vault = try OwnerKASVault.seal(Self.secret, with: prf(), binding: Self.binding)

        assertVaultError(.wrongPasskey) {
            try vault.open(with: prf(credentialID: Data([0x01])), binding: Self.binding)
        }
        assertVaultError(.wrongPasskey) {
            try vault.open(with: prf(input: Data(repeating: 0x12, count: 32)), binding: Self.binding)
        }
        assertVaultError(.wrongPasskey) {
            try vault.open(with: prf(relyingPartyID: "other.example.test"), binding: Self.binding)
        }
    }

    // MARK: - The contract's bytes

    /// HKDF-SHA-256 with the contract's info, checked against OpenSSL:
    /// `openssl kdf -keylen 32 -kdfopt digest:SHA256 -kdfopt hexkey:42…42 -kdfopt hexsalt:0102…20
    /// -kdfopt info:arkavo.owner-kas.vault/v1 HKDF`.
    func testTheWrappingKeyIsHKDFSHA256WithTheContractInfo() {
        XCTAssertEqual(OwnerKASVault.hkdfInfo, Data("arkavo.owner-kas.vault/v1".utf8))

        let key = OwnerKASVault.wrappingKey(prf: SymmetricKey(data: Self.prfBytes), salt: Data(1 ... 32))

        XCTAssertEqual(
            key.withUnsafeBytes { Data($0) },
            Data(hex: "d6f73a390281ff0640e412cfd21774bd994ef900845e32a44b032e4507b0284b")
        )
    }

    func testAssociatedDataIsLengthPrefixedUTF8() {
        let binding = OwnerKASVaultBinding(vaultID: "v", ownerSubject: "sü", kasKeyID: "", algorithm: "alg")

        var expected = Data([0, 0, 0, 1])
        expected.append(Data("v".utf8))
        expected.append(Data([0, 0, 0, 3])) // "sü" is three UTF-8 bytes
        expected.append(Data("sü".utf8))
        expected.append(Data([0, 0, 0, 0]))
        expected.append(Data([0, 0, 0, 3]))
        expected.append(Data("alg".utf8))
        XCTAssertEqual(binding.associatedData, expected)
    }

    /// A vault sealed by this version with salt 01…20 and nonce a0…ab. Every later version must keep opening it.
    private static let vector = #"""
    {"blob":"MhQqFVKGnuCSXR7z/9ktG+Pc6f/6UssSAVUBJdlRVGCA8On6k5A=","credentialId":"wP/u","nonce":"oKGio6Slpqeoqaqr","prfInput":"ERERERERERERERERERERERERERERERERERERERERERE=","rpId":"identity.example.test","salt":"AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=","v":1}
    """#

    func testAKnownVaultStillOpens() throws {
        let vault = try OwnerKASVault(encoded: Data(Self.vector.utf8))

        XCTAssertEqual(try vault.open(with: prf(), binding: Self.binding), Self.secret)
    }

    func testAFixedSaltAndNonceGiveTheKnownVault() throws {
        let vault = try OwnerKASVault.seal(
            Self.secret,
            with: prf(),
            binding: Self.binding,
            salt: Data(1 ... 32),
            nonce: AES.GCM.Nonce(data: Data(0xA0 ... 0xAB))
        )

        XCTAssertEqual(String(decoding: try vault.encoded(), as: UTF8.self), Self.vector)
    }

    // MARK: - Encoding

    func testTheEncodingRoundTripsWithTheContractKeys() throws {
        let vault = try OwnerKASVault.seal(Self.secret, with: prf(), binding: Self.binding)
        let encoded = try vault.encoded()

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "rpId", "credentialId", "prfInput", "salt", "nonce", "blob"])
        XCTAssertEqual(try OwnerKASVault(encoded: encoded), vault)
    }

    func testAnUnknownVersionIsRefused() throws {
        let v2 = Self.vector.replacingOccurrences(of: #""v":1"#, with: #""v":2"#)

        assertVaultError(.unsupportedVersion(2)) { try OwnerKASVault(encoded: Data(v2.utf8)) }
    }

    func testMalformedFieldsAreRefused() throws {
        let vault = try OwnerKASVault.seal(Self.secret, with: prf(), binding: Self.binding)
        var shortSalt = vault
        shortSalt.salt = Data(count: 31)
        var shortNonce = vault
        shortNonce.nonce = Data(count: 11)
        var noTag = vault
        noTag.blob = Data(count: 15)
        var noCredential = vault
        noCredential.credentialID = Data()
        var noInput = vault
        noInput.prfInput = Data()

        for malformed in [shortSalt, shortNonce, noTag, noCredential, noInput] {
            let encoded = try JSONEncoder().encode(malformed)
            assertVaultError(.malformed) { try OwnerKASVault(encoded: encoded) }
        }
        assertVaultError(.malformed) { try OwnerKASVault(encoded: Data("{}".utf8)) }
        assertVaultError(.malformed) { try OwnerKASVault(encoded: Data("not json".utf8)) }
    }

    // MARK: - No leakage

    func testThePRFOutputNeverShowsItsBytes() {
        let output = prf()
        var dumped = ""
        dump(output, to: &dumped)
        let rendered = [String(describing: output), String(reflecting: output), dumped]

        for text in rendered {
            XCTAssertFalse(text.contains("66, 66"), text) // decimal bytes
            XCTAssertFalse(text.lowercased().contains("4242"), text) // hex
            XCTAssertFalse(text.contains("QkJC"), text) // base64
        }
        XCTAssertTrue(Mirror(reflecting: output).children.isEmpty)
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
