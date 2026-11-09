import CryptoKit
import Foundation

// The owner-KAS vault (ArkavoKit#73, arkavo-ios owner-KAS design §4.7). The owner's KAS private key (and
// service key) at rest, sealed under the owner's passkey PRF output:
//
//   key  = HKDF-SHA-256(IKM: PRF output, salt: 32 random bytes, info: "arkavo.owner-kas.vault/v1", L: 32)
//   blob = AES-256-GCM(key, nonce: 12 random bytes, AAD: the binding) → ciphertext ‖ 16-byte tag
//
// Every seal draws a fresh salt and nonce. The binding (vault ID, owner subject, KAS key ID, algorithm) is
// authenticated, not stored: the caller supplies it again to open. The PRF output and the derived key are
// never stored, logged or returned. ArkavoKit stores nothing; the app keeps the encoded vault.

/// What a vault is bound to. Sealing and opening must give the same four values.
public struct OwnerKASVaultBinding: Sendable, Hashable {
    public let vaultID: String
    /// The owner's identity subject (`sub`).
    public let ownerSubject: String
    /// The ID of the KAS key the vault holds.
    public let kasKeyID: String
    /// The KAS key's algorithm, e.g. `ec:secp256r1`.
    public let algorithm: String

    public init(vaultID: String, ownerSubject: String, kasKeyID: String, algorithm: String) {
        self.vaultID = vaultID
        self.ownerSubject = ownerSubject
        self.kasKeyID = kasKeyID
        self.algorithm = algorithm
    }

    /// The AES-GCM associated data: each field as a 4-byte big-endian length and its UTF-8 bytes, in the
    /// order vault ID, owner subject, KAS key ID, algorithm.
    var associatedData: Data {
        var data = Data()
        for field in [vaultID, ownerSubject, kasKeyID, algorithm] {
            let bytes = Data(field.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return data
    }
}

/// Why a vault did not open or decode.
public enum OwnerKASVaultError: Error, Sendable, Equatable {
    /// The PRF output came from another passkey, PRF input or relying party than the vault's. Nothing was decrypted.
    case wrongPasskey
    /// Authentication failed: the binding is not the one the vault was sealed with, or the vault was altered.
    case cannotOpen
    /// A vault version this ArkavoKit does not read.
    case unsupportedVersion(Int)
    /// An encoded vault with a missing or wrong-sized field.
    case malformed
}

/// A secret sealed under a passkey's PRF output. Holds no key; `encoded()` is safe to write to disk.
public struct OwnerKASVault: Sendable, Equatable, Codable {
    /// The version `seal` writes and `open` reads.
    public static let currentVersion = 1

    public internal(set) var version: Int
    /// The relying party of the passkey that opens the vault.
    public internal(set) var relyingPartyID: String
    /// The passkey that opens the vault.
    public internal(set) var credentialID: Data
    /// The PRF input the passkey evaluates (32 random bytes, fixed for the vault's life).
    public internal(set) var prfInput: Data
    /// The HKDF salt (32 random bytes, new at every seal).
    public internal(set) var salt: Data
    /// The AES-GCM nonce (12 random bytes, new at every seal).
    public internal(set) var nonce: Data
    /// The ciphertext followed by the 16-byte tag.
    public internal(set) var blob: Data

    static let hkdfInfo = Data("arkavo.owner-kas.vault/v1".utf8)
    static let saltByteCount = 32
    static let nonceByteCount = 12
    static let tagByteCount = 16

    /// A PRF input for a new vault: 32 random bytes.
    public static func newPRFInput() -> Data {
        secureRandomBytes(32)
    }

    /// Seals `secret` under `prf`, with a fresh salt and nonce. The vault records `prf`'s passkey and input.
    public static func seal(
        _ secret: Data,
        with prf: PasskeyPRFOutput,
        binding: OwnerKASVaultBinding
    ) throws -> OwnerKASVault {
        try seal(secret, with: prf, binding: binding, salt: secureRandomBytes(saltByteCount), nonce: AES.GCM.Nonce())
    }

    static func seal(
        _ secret: Data,
        with prf: PasskeyPRFOutput,
        binding: OwnerKASVaultBinding,
        salt: Data,
        nonce: AES.GCM.Nonce
    ) throws -> OwnerKASVault {
        let box = try AES.GCM.seal(
            secret,
            using: wrappingKey(prf: prf.key, salt: salt),
            nonce: nonce,
            authenticating: binding.associatedData
        )
        return OwnerKASVault(
            version: currentVersion,
            relyingPartyID: prf.relyingPartyID,
            credentialID: prf.credentialID,
            prfInput: prf.input,
            salt: salt,
            nonce: nonce.withUnsafeBytes { Data($0) },
            blob: box.ciphertext + box.tag
        )
    }

    /// The secret, when `prf` is this vault's passkey at its input and `binding` is the one it was sealed with.
    ///
    /// - Throws: `OwnerKASVaultError.wrongPasskey` before decrypting when `prf` is another passkey, input or
    ///   relying party; `.cannotOpen` when authentication fails.
    public func open(with prf: PasskeyPRFOutput, binding: OwnerKASVaultBinding) throws -> Data {
        guard version == Self.currentVersion else {
            throw OwnerKASVaultError.unsupportedVersion(version)
        }
        guard prf.relyingPartyID == relyingPartyID, prf.credentialID == credentialID, prf.input == prfInput else {
            throw OwnerKASVaultError.wrongPasskey
        }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: blob.dropLast(Self.tagByteCount),
                tag: blob.suffix(Self.tagByteCount)
            )
            return try AES.GCM.open(box, using: Self.wrappingKey(prf: prf.key, salt: salt), authenticating: binding.associatedData)
        } catch {
            throw OwnerKASVaultError.cannotOpen
        }
    }

    static func wrappingKey(prf: SymmetricKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: prf, salt: salt, info: hkdfInfo, outputByteCount: 32)
    }

    // MARK: - Encoding

    /// The vault as JSON: `{"blob","credentialId","nonce","prfInput","rpId","salt","v"}`, byte strings in
    /// standard base64, keys sorted.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// A vault from `encoded()`.
    ///
    /// - Throws: `OwnerKASVaultError.unsupportedVersion` for another version; `.malformed` otherwise.
    public init(encoded: Data) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: encoded)
        } catch let error as OwnerKASVaultError {
            throw error
        } catch {
            throw OwnerKASVaultError.malformed
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case relyingPartyID = "rpId"
        case credentialID = "credentialId"
        case prfInput
        case salt
        case nonce
        case blob
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw OwnerKASVaultError.unsupportedVersion(version)
        }
        self.init(
            version: version,
            relyingPartyID: try container.decode(String.self, forKey: .relyingPartyID),
            credentialID: try container.decode(Data.self, forKey: .credentialID),
            prfInput: try container.decode(Data.self, forKey: .prfInput),
            salt: try container.decode(Data.self, forKey: .salt),
            nonce: try container.decode(Data.self, forKey: .nonce),
            blob: try container.decode(Data.self, forKey: .blob)
        )
        guard !relyingPartyID.isEmpty, !credentialID.isEmpty, !prfInput.isEmpty,
              salt.count == Self.saltByteCount, nonce.count == Self.nonceByteCount,
              blob.count >= Self.tagByteCount
        else {
            throw OwnerKASVaultError.malformed
        }
    }

    private init(
        version: Int,
        relyingPartyID: String,
        credentialID: Data,
        prfInput: Data,
        salt: Data,
        nonce: Data,
        blob: Data
    ) {
        self.version = version
        self.relyingPartyID = relyingPartyID
        self.credentialID = credentialID
        self.prfInput = prfInput
        self.salt = salt
        self.nonce = nonce
        self.blob = blob
    }
}
