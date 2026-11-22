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

    /// Serialize payload to binary format per NTDF spec, rejecting any field
    /// that exceeds its wire-format length limit.
    public func toBytesChecked() throws -> Data {
        guard scopes.count <= Int(UInt16.max) else {
            throw NTDFTokenError.serializationFailed("Too many scopes: \(scopes.count)")
        }
        for scope in scopes {
            let scopeCount = scope.utf8.count
            guard scopeCount <= Int(UInt8.max) else {
                throw NTDFTokenError.serializationFailed("Scope exceeds 255 UTF-8 bytes (\(scopeCount))")
            }
        }
        guard attrs.count <= Int(UInt16.max) else {
            throw NTDFTokenError.serializationFailed("Too many attributes: \(attrs.count)")
        }
        let audCount = aud.utf8.count
        guard audCount <= Int(UInt16.max) else {
            throw NTDFTokenError.serializationFailed("Audience exceeds 65535 UTF-8 bytes (\(audCount))")
        }
        if let deviceId {
            let deviceCount = deviceId.utf8.count
            guard deviceCount <= Int(UInt8.max) else {
                throw NTDFTokenError.serializationFailed("deviceId exceeds 255 UTF-8 bytes (\(deviceCount))")
            }
        }
        if let did {
            let didCount = did.utf8.count
            guard didCount <= Int(UInt16.max) else {
                throw NTDFTokenError.serializationFailed("did exceeds 65535 UTF-8 bytes (\(didCount))")
            }
        }
        return toBytes()
    }

    /// Serialize payload to binary format per NTDF spec.
    /// Safely clamps any oversized fields to wire-format limits instead of trapping.
    public func toBytes() -> Data {
        var buf = Data()

        // sub_id (16 bytes)
        let uuidBytes = withUnsafeBytes(of: subId.uuid) { Data($0) }
        buf.append(uuidBytes)

        // flags (8 bytes, u64 little-endian)
        var flagsValue = flags.rawValue.littleEndian
        buf.append(contentsOf: withUnsafeBytes(of: &flagsValue) { Data($0) })

        // scopes_count (2 bytes, u16 little-endian)
        let clampedScopes = scopes.prefix(Int(UInt16.max))
        var scopesCount = UInt16(clampedScopes.count).littleEndian
        buf.append(contentsOf: withUnsafeBytes(of: &scopesCount) { Data($0) })

        // scopes (length-prefixed strings, max 255 UTF-8 bytes each)
        for scope in clampedScopes {
            let scopeData = Self.truncateUTF8(scope, maxBytes: Int(UInt8.max))
            buf.append(UInt8(scopeData.count))
            buf.append(scopeData)
        }

        // attrs_count (2 bytes, u16 little-endian)
        let clampedAttrs = attrs.prefix(Int(UInt16.max))
        var attrsCount = UInt16(clampedAttrs.count).littleEndian
        buf.append(contentsOf: withUnsafeBytes(of: &attrsCount) { Data($0) })

        // attrs (type: 1 byte, value: 4 bytes little-endian)
        for (attrType, attrValue) in clampedAttrs {
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
        let audData = Self.truncateUTF8(aud, maxBytes: Int(UInt16.max))
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
            let deviceIdData = Self.truncateUTF8(deviceId, maxBytes: Int(UInt8.max))
            buf.append(1)
            buf.append(UInt8(deviceIdData.count))
            buf.append(deviceIdData)
        } else {
            buf.append(0)
        }

        // did_present (1 byte)
        if let did {
            let didData = Self.truncateUTF8(did, maxBytes: Int(UInt16.max))
            buf.append(1)
            var didLength = UInt16(didData.count).littleEndian
            buf.append(contentsOf: withUnsafeBytes(of: &didLength) { Data($0) })
            buf.append(didData)
        } else {
            buf.append(0)
        }

        return buf
    }

    private static func truncateUTF8(_ value: String, maxBytes: Int) -> Data {
        let full = Data(value.utf8)
        if full.count <= maxBytes {
            return full
        }
        var result = Data()
        result.reserveCapacity(maxBytes)
        for scalar in value.unicodeScalars {
            let scalarBytes = scalar.utf8
            if result.count + scalarBytes.count > maxBytes {
                break
            }
            result.append(contentsOf: scalarBytes)
        }
        return result
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

        // 1. Serialize payload to binary (validating wire limits)
        let plaintext = try payload.toBytesChecked()
        print("📦 Payload serialized: \(plaintext.count) bytes")

        // 2. Create KasMetadata (validating scheme and preserving non-default port)
        let locator = try Self.makeResourceLocator(from: kasURL)

        let p256PublicKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: kasPublicKeyBytes)
        let kasMetadata = try KasMetadata(
            resourceLocator: locator,
            publicKey: p256PublicKey,
            curve: .secp256r1
        )

        // 3. Create NanoTDF with a minimal non-sensitive policy header so
        // authentication claims remain encrypted in the NanoTDF payload only.
        let policyUUID = UUID().uuidString.lowercased()
        let policyJSON = "{\"uuid\":\"\(policyUUID)\",\"body\":{\"dataAttributes\":[],\"dissem\":[]}}"
        var policy = Policy(
            type: .embeddedPlaintext,
            body: EmbeddedPolicyBody(body: Data(policyJSON.utf8)),
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

    static func makeResourceLocator(from urlString: String) throws -> ResourceLocator {
        guard let parsed = URL(string: urlString),
              let host = parsed.host, !host.isEmpty,
              let scheme = parsed.scheme?.lowercased() else {
            throw NTDFTokenError.invalidKeyFormat("Invalid KAS URL: \(urlString)")
        }

        let isLoopback = KASPublicKeyService.isLoopbackHost(host)
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw NTDFTokenError.invalidKeyFormat("KAS URL must use HTTPS (got \(scheme)://\(host))")
        }

        let protocolEnum: ProtocolEnum = scheme == "https" ? .https : .http
        let defaultPort = scheme == "https" ? 443 : 80
        let body: String
        if let port = parsed.port, port != defaultPort {
            body = "\(host):\(port)"
        } else {
            body = host
        }

        guard let resourceLocator = ResourceLocator(protocolEnum: protocolEnum, body: body) else {
            throw NTDFTokenError.invalidKeyFormat("Failed to create ResourceLocator for \(body)")
        }
        return resourceLocator
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

    /// Encode binary data to Z85 string.
    ///
    /// Note: Per ZeroMQ RFC 32, Z85 operates on 4-byte blocks. Inputs whose byte
    /// length is not a multiple of 4 are right-padded with zero bytes (required by
    /// NanoTDF token framing); callers requiring lossless round-trip of arbitrary
    /// lengths should use `encodeExact(_:)` on 4-byte-aligned inputs or frame the
    /// original byte length separately.
    /// - Parameter data: Binary data to encode (slices with non-zero startIndex are supported)
    /// - Returns: Z85-encoded string
    public static func encode(_ data: Data) -> String {
        // Normalize slice startIndex to 0 and pad to multiple of 4 bytes
        var paddedData = data.startIndex == 0 ? data : Data(data)
        let remainder = paddedData.count % 4
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

    /// Strict RFC 32 Z85 encode: returns `nil` if `data.count` is not a multiple of 4,
    /// guaranteeing exact byte-length round-trip through `decode(_:)`.
    public static func encodeExact(_ data: Data) -> String? {
        guard data.count % 4 == 0 else {
            return nil
        }
        return encode(data)
    }

    /// Decode Z85 string to binary data
    /// - Parameter string: Z85-encoded string
    /// - Returns: Decoded binary data, or nil if invalid or a 5-character block overflows UInt32
    public static func decode(_ string: String) -> Data? {
        let bytes = Array(string.utf8)
        guard bytes.count % 5 == 0 else {
            return nil
        }

        var result = Data()
        result.reserveCapacity((bytes.count / 5) * 4)

        for i in stride(from: 0, to: bytes.count, by: 5) {
            var value: UInt64 = 0
            for j in 0..<5 {
                guard let decoded = decodeTable[bytes[i + j]] else {
                    return nil
                }
                value = value * 85 + UInt64(decoded)
            }

            // Valid 5-character Z85 alphabet blocks can represent up to 85^5 - 1 > UInt32.max.
            guard value <= UInt64(UInt32.max) else {
                return nil
            }

            let word = UInt32(value)
            // Write 4 bytes in big-endian order
            result.append(UInt8((word >> 24) & 0xFF))
            result.append(UInt8((word >> 16) & 0xFF))
            result.append(UInt8((word >> 8) & 0xFF))
            result.append(UInt8(word & 0xFF))
        }

        return result
    }
}
