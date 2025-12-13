import CryptoKit
import Foundation
import OpenTDFKit

/// Capability flags for NTDF token payload
public struct NTDFCapabilityFlag: OptionSet, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let profile = NTDFCapabilityFlag(rawValue: 0x01)
    public static let openId = NTDFCapabilityFlag(rawValue: 0x02)
    public static let email = NTDFCapabilityFlag(rawValue: 0x04)
    public static let offlineAccess = NTDFCapabilityFlag(rawValue: 0x08)
    public static let deviceAttested = NTDFCapabilityFlag(rawValue: 0x10)
    public static let biometricAuth = NTDFCapabilityFlag(rawValue: 0x20)
    public static let webAuthn = NTDFCapabilityFlag(rawValue: 0x40)
    public static let platformSecure = NTDFCapabilityFlag(rawValue: 0x80)
}

/// Attribute types for NTDF token payload
public enum NTDFAttributeType: UInt8, Sendable {
    case age = 0
    case subscriptionTier = 1
    case securityLevel = 2
    case platformCode = 3
}

/// NTDF token payload containing authentication claims
public struct NTDFTokenPayload: Sendable {
    /// Subject UUID (16 bytes)
    public let subId: UUID
    /// Capability flags (bitfield)
    public let flags: NTDFCapabilityFlag
    /// OAuth scopes
    public let scopes: [String]
    /// Typed attributes (type, value)
    public let attrs: [(UInt8, UInt32)]
    /// DPoP JTI for proof-of-possession binding (optional)
    public let dpopJti: UUID?
    /// Issued at (Unix timestamp)
    public let iat: Int64
    /// Expiration (Unix timestamp)
    public let exp: Int64
    /// Audience (target service)
    public let aud: String
    /// Session tracking ID (optional)
    public let sessionId: UUID?
    /// Device identifier (optional)
    public let deviceId: String?
    /// Decentralized Identifier (optional)
    public let did: String?

    public init(
        subId: UUID,
        flags: NTDFCapabilityFlag,
        scopes: [String],
        attrs: [(UInt8, UInt32)] = [],
        dpopJti: UUID? = nil,
        iat: Int64,
        exp: Int64,
        aud: String,
        sessionId: UUID? = nil,
        deviceId: String? = nil,
        did: String? = nil
    ) {
        self.subId = subId
        self.flags = flags
        self.scopes = scopes
        self.attrs = attrs
        self.dpopJti = dpopJti
        self.iat = iat
        self.exp = exp
        self.aud = aud
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.did = did
    }

    /// Serialize payload to binary format per NTDF spec
    public func toBytes() -> Data {
        var buf = Data()

        // sub_id (16 bytes)
        let uuidBytes = withUnsafeBytes(of: subId.uuid) { Data($0) }
        buf.append(uuidBytes)

        // flags (8 bytes, u64 little-endian)
        var flagsValue = flags.rawValue.littleEndian
        buf.append(contentsOf: withUnsafeBytes(of: &flagsValue) { Data($0) })

        // scopes_count (2 bytes, u16 little-endian)
        var scopesCount = UInt16(scopes.count).littleEndian
        buf.append(contentsOf: withUnsafeBytes(of: &scopesCount) { Data($0) })

        // scopes (length-prefixed strings)
        for scope in scopes {
            let scopeData = scope.data(using: .utf8) ?? Data()
            buf.append(UInt8(scopeData.count))
            buf.append(scopeData)
        }

        // attrs_count (2 bytes, u16 little-endian)
        var attrsCount = UInt16(attrs.count).littleEndian
        buf.append(contentsOf: withUnsafeBytes(of: &attrsCount) { Data($0) })

        // attrs (type: 1 byte, value: 4 bytes little-endian)
        for (attrType, attrValue) in attrs {
            buf.append(attrType)
            var value = attrValue.littleEndian
            buf.append(contentsOf: withUnsafeBytes(of: &value) { Data($0) })
        }

        // dpop_jti_present (1 byte)
        if let jti = dpopJti {
            buf.append(1)
            let jtiBytes = withUnsafeBytes(of: jti.uuid) { Data($0) }
            buf.append(jtiBytes)
        } else {
            buf.append(0)
        }

        // iat (8 bytes, i64 little-endian)
        var iatValue = iat.littleEndian
        buf.append(contentsOf: withUnsafeBytes(of: &iatValue) { Data($0) })

        // exp (8 bytes, i64 little-endian)
        var expValue = exp.littleEndian
        buf.append(contentsOf: withUnsafeBytes(of: &expValue) { Data($0) })

        // aud_length (2 bytes, u16 little-endian) + aud
        let audData = aud.data(using: .utf8) ?? Data()
        var audLength = UInt16(audData.count).littleEndian
        buf.append(contentsOf: withUnsafeBytes(of: &audLength) { Data($0) })
        buf.append(audData)

        // session_id_present (1 byte)
        if let sid = sessionId {
            buf.append(1)
            let sidBytes = withUnsafeBytes(of: sid.uuid) { Data($0) }
            buf.append(sidBytes)
        } else {
            buf.append(0)
        }

        // device_id_present (1 byte)
        if let deviceId {
            let deviceIdData = deviceId.data(using: .utf8) ?? Data()
            buf.append(1)
            buf.append(UInt8(deviceIdData.count))
            buf.append(deviceIdData)
        } else {
            buf.append(0)
        }

        // did_present (1 byte)
        if let did {
            let didData = did.data(using: .utf8) ?? Data()
            buf.append(1)
            var didLength = UInt16(didData.count).littleEndian
            buf.append(contentsOf: withUnsafeBytes(of: &didLength) { Data($0) })
            buf.append(didData)
        } else {
            buf.append(0)
        }

        return buf
    }
}

/// Errors that can occur during NTDF token generation
public enum NTDFTokenError: Error, LocalizedError {
    case noKasPublicKey
    case encryptionFailed(String)
    case serializationFailed(String)
    case invalidKeyFormat(String)

    public var errorDescription: String? {
        switch self {
        case .noKasPublicKey:
            return "KAS public key not configured"
        case .encryptionFailed(let message):
            return "NanoTDF encryption failed: \(message)"
        case .serializationFailed(let message):
            return "NanoTDF serialization failed: \(message)"
        case .invalidKeyFormat(let message):
            return "Invalid key format: \(message)"
        }
    }
}

/// Builder for generating NTDF tokens
public actor NTDFTokenBuilder {
    /// KAS public key bytes (compressed SEC1 format, 33 bytes)
    private let kasPublicKeyBytes: Data
    /// KAS URL to embed in token header
    private let kasURL: String

    /// Create a new NTDF token builder
    /// - Parameters:
    ///   - kasPublicKey: The KAS P-256 public key (33 bytes compressed)
    ///   - kasURL: The KAS URL to embed in the token header
    public init(kasPublicKey: Data, kasURL: String) {
        self.kasPublicKeyBytes = kasPublicKey
        self.kasURL = kasURL
    }

    /// Build an NTDF token from the given payload
    /// - Parameter payload: The token payload containing claims
    /// - Returns: A Z85-encoded NanoTDF token string
    public func build(payload: NTDFTokenPayload) async throws -> String {
        print("🔐 Building NTDF token for subId=\(payload.subId)")

        // 1. Serialize payload to binary
        let plaintext = payload.toBytes()
        print("📦 Payload serialized: \(plaintext.count) bytes")

        // 2. Create KasMetadata
        let host = URL(string: kasURL)?.host ?? "kas.arkavo.net"
        guard let resourceLocator = ResourceLocator(protocolEnum: .https, body: host) else {
            throw NTDFTokenError.invalidKeyFormat("Failed to create ResourceLocator for \(host)")
        }

        let p256PublicKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: kasPublicKeyBytes)
        let kasMetadata = try KasMetadata(
            resourceLocator: resourceLocator,
            publicKey: p256PublicKey,
            curve: .secp256r1
        )

        // 3. Create NanoTDF with embedded plaintext policy containing the payload
        var policy = Policy(
            type: .embeddedPlaintext,
            body: EmbeddedPolicyBody(body: plaintext),
            remote: nil
        )

        // Use v12 format for compatibility with the Rust implementation
        let nanoTDF = try await createNanoTDFv12(
            kas: kasMetadata,
            policy: &policy,
            plaintext: plaintext
        )

        // 4. Serialize to bytes
        let nanoTDFBytes = nanoTDF.toData()
        print("🔐 NanoTDF serialized: \(nanoTDFBytes.count) bytes")

        // 5. Z85 encode
        let z85Token = Z85.encode(nanoTDFBytes)
        print("✅ NTDF token generated: \(z85Token.count) chars")

        return z85Token
    }
}

// MARK: - Z85 Encoding

/// Z85 encoding implementation per ZeroMQ RFC 32
/// https://rfc.zeromq.org/spec/32/
public enum Z85 {
    // Z85 character set (85 characters)
    private static let chars: [Character] = Array(
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#"
    )

    // Reverse lookup table for decoding
    private static let decodeTable: [UInt8: UInt8] = {
        var table: [UInt8: UInt8] = [:]
        for (i, char) in chars.enumerated() {
            table[UInt8(char.asciiValue!)] = UInt8(i)
        }
        return table
    }()

    /// Encode binary data to Z85 string
    /// - Parameter data: Binary data to encode (will be padded to multiple of 4 bytes)
    /// - Returns: Z85-encoded string
    public static func encode(_ data: Data) -> String {
        // Pad to multiple of 4 bytes
        var paddedData = data
        let remainder = data.count % 4
        if remainder != 0 {
            let padding = 4 - remainder
            paddedData.append(contentsOf: [UInt8](repeating: 0, count: padding))
        }

        var result = ""
        result.reserveCapacity((paddedData.count / 4) * 5)

        for i in stride(from: 0, to: paddedData.count, by: 4) {
            // Read 4 bytes as big-endian UInt32
            var value = UInt32(paddedData[i]) << 24
            value |= UInt32(paddedData[i + 1]) << 16
            value |= UInt32(paddedData[i + 2]) << 8
            value |= UInt32(paddedData[i + 3])

            // Convert to 5 Z85 characters
            var encoded = [Character](repeating: "0", count: 5)
            for j in (0..<5).reversed() {
                encoded[j] = chars[Int(value % 85)]
                value /= 85
            }
            result.append(contentsOf: encoded)
        }

        return result
    }

    /// Decode Z85 string to binary data
    /// - Parameter string: Z85-encoded string
    /// - Returns: Decoded binary data, or nil if invalid
    public static func decode(_ string: String) -> Data? {
        guard string.count % 5 == 0 else {
            return nil
        }

        var result = Data()
        result.reserveCapacity((string.count / 5) * 4)

        let bytes = Array(string.utf8)
        for i in stride(from: 0, to: bytes.count, by: 5) {
            var value: UInt32 = 0
            for j in 0..<5 {
                guard let decoded = decodeTable[bytes[i + j]] else {
                    return nil
                }
                value = value * 85 + UInt32(decoded)
            }

            // Write 4 bytes in big-endian order
            result.append(UInt8((value >> 24) & 0xFF))
            result.append(UInt8((value >> 16) & 0xFF))
            result.append(UInt8((value >> 8) & 0xFF))
            result.append(UInt8(value & 0xFF))
        }

        return result
    }
}
