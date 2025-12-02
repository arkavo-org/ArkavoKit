import Foundation
import OpenTDFKit
import CryptoKit

/// Error types for KAS public key operations
public enum KASPublicKeyError: Error, LocalizedError {
    case networkError(String)
    case invalidResponse
    case invalidPublicKey(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse:
            return "Invalid response from KAS server"
        case .invalidPublicKey(let message):
            return "Invalid public key: \(message)"
        case .parseError(let message):
            return "Parse error: \(message)"
        }
    }
}

/// Service for fetching and caching KAS public key
public actor KASPublicKeyService {
    private let kasURL: URL
    private var cachedPublicKey: Data?
    private var cachedKasMetadata: KasMetadata?

    public init(kasURL: URL) {
        self.kasURL = kasURL
    }

    /// Fetch KAS public key from /kas/v2/kas_public_key endpoint
    /// Returns compressed P-256 public key (33 bytes)
    public func fetchPublicKey() async throws -> Data {
        // Return cached key if available
        if let cached = cachedPublicKey {
            return cached
        }

        // Build endpoint URL
        var components = URLComponents(url: kasURL, resolvingAgainstBaseURL: false)!
        components.path = "/kas/v2/kas_public_key"
        components.queryItems = [URLQueryItem(name: "algorithm", value: "ec")]

        guard let url = components.url else {
            throw KASPublicKeyError.parseError("Failed to construct KAS URL")
        }

        print("📡 Fetching KAS public key from \(url)")

        // Fetch public key
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw KASPublicKeyError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Response is PEM-encoded public key
        guard let pemString = String(data: data, encoding: .utf8) else {
            throw KASPublicKeyError.invalidResponse
        }

        // Parse PEM to extract DER-encoded public key
        let publicKeyData = try parsePEMPublicKey(pemString)

        // Cache the result
        cachedPublicKey = publicKeyData

        print("✅ Got KAS public key: \(publicKeyData.count) bytes")
        return publicKeyData
    }

    /// Create KasMetadata for NanoTDFCollectionBuilder
    public func createKasMetadata() async throws -> KasMetadata {
        // Return cached metadata if available
        if let cached = cachedKasMetadata {
            return cached
        }

        let publicKeyData = try await fetchPublicKey()

        // Create ResourceLocator from KAS URL
        let host = kasURL.host ?? "localhost"
        let protocolEnum: ProtocolEnum = kasURL.scheme == "https" ? .https : .http

        guard let resourceLocator = ResourceLocator(protocolEnum: protocolEnum, body: host) else {
            throw KASPublicKeyError.parseError("Failed to create ResourceLocator for \(host)")
        }

        // Convert compressed public key data to P256 public key
        let p256PublicKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: publicKeyData)

        // Create KasMetadata with the public key
        let kasMetadata = try KasMetadata(
            resourceLocator: resourceLocator,
            publicKey: p256PublicKey,
            curve: .secp256r1
        )

        // Cache the result
        cachedKasMetadata = kasMetadata

        print("✅ Created KasMetadata for \(host)")
        return kasMetadata
    }

    /// Parse PEM-encoded public key to extract raw key data
    private func parsePEMPublicKey(_ pem: String) throws -> Data {
        // Remove PEM headers and whitespace
        let base64String = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let keyData = Data(base64Encoded: base64String) else {
            throw KASPublicKeyError.parseError("Invalid base64 in PEM")
        }

        // The KAS server returns raw uncompressed EC point (65 bytes: 0x04 || x || y)
        // wrapped in PEM-like headers, not standard SPKI format.
        // We also support standard SPKI format (91+ bytes) for compatibility.

        let uncompressedPoint: Data

        if keyData.count == 65 && keyData[0] == 0x04 {
            // Raw uncompressed point format from KAS server
            uncompressedPoint = keyData
        } else if keyData.count >= 91 {
            // Standard SPKI format - extract the point from after the header
            // SPKI header for P-256 is 26 bytes
            let spkiHeaderLength = 26
            guard keyData.count >= spkiHeaderLength + 65 else {
                throw KASPublicKeyError.invalidPublicKey("SPKI data too short: \(keyData.count) bytes")
            }
            uncompressedPoint = keyData.subdata(in: spkiHeaderLength..<(spkiHeaderLength + 65))
        } else {
            throw KASPublicKeyError.invalidPublicKey("Unexpected key format: \(keyData.count) bytes")
        }

        guard uncompressedPoint[0] == 0x04 else {
            throw KASPublicKeyError.invalidPublicKey("Expected uncompressed point (0x04), got 0x\(String(format: "%02x", uncompressedPoint[0]))")
        }

        // Convert to compressed format
        // Compressed point: 0x02 (even y) or 0x03 (odd y) || x-coordinate
        let xCoord = uncompressedPoint.subdata(in: 1..<33)
        let yCoord = uncompressedPoint.subdata(in: 33..<65)

        // Check if y is even or odd (last byte of y)
        let yIsOdd = yCoord[31] & 0x01 == 1
        let prefix: UInt8 = yIsOdd ? 0x03 : 0x02

        var compressedPoint = Data([prefix])
        compressedPoint.append(xCoord)

        return compressedPoint
    }

    /// Clear cached values (for testing or refresh)
    public func clearCache() {
        cachedPublicKey = nil
        cachedKasMetadata = nil
    }
}
