import ArkavoMediaKit
import Foundation
import ZIPFoundation

/// TDF3-based content protection service for FairPlay-compatible video encryption
///
/// Uses Standard TDF format (ZIP archive containing manifest.json + 0.payload) with:
/// - AES-128-CBC for content encryption (FairPlay compatible)
/// - RSA-2048 OAEP (SHA-1) for DEK wrapping (OpenTDF spec)
public actor TDFProtectionService {
    private let kasURL: URL

    /// Initialize with KAS URL for key fetching
    /// - Parameter kasURL: KAS server URL (e.g., https://100.arkavo.net)
    public init(kasURL: URL) {
        self.kasURL = kasURL
    }

    /// Protect content using Standard TDF format for FairPlay delivery
    /// - Parameters:
    ///   - data: Raw data to encrypt
    ///   - assetID: Unique asset identifier for the manifest
    ///   - mimeType: MIME type of the content (default: video/quicktime)
    /// - Returns: TDF ZIP archive data containing manifest.json and 0.payload
    public func protect(
        data: Data,
        assetID: String,
        mimeType: String = "video/quicktime"
    ) async throws -> Data {
        // 1. Generate 16-byte DEK (AES-128 for FairPlay)
        let dek = try TDFProtectionCore.generateDEK()

        // 2. Generate random 16-byte IV
        let iv = try TDFProtectionCore.generateIV()

        // 3. Encrypt data with AES-128-CBC
        let ciphertext = try TDFProtectionCore.encryptCBC(plaintext: data, key: dek, iv: iv)

        // 4. Fetch KAS RSA public key
        let rsaPublicKeyPEM = try await TDFProtectionCore.fetchKASRSAPublicKey(kasURL: kasURL)

        // 5. Wrap DEK with RSA-2048 OAEP (SHA-1 per OpenTDF spec)
        let wrappedKey = try TDFProtectionCore.wrapDEKWithRSA(dek: dek, publicKeyPEM: rsaPublicKeyPEM)

        // 6. Build Standard TDF manifest.json
        let manifest = try TDFProtectionCore.buildManifest(
            kasURL: kasURL,
            wrappedKey: wrappedKey,
            iv: iv,
            assetID: assetID,
            mimeType: mimeType
        )

        // 7. Create TDF ZIP archive containing manifest.json and 0.payload
        let tdfArchive = try createTDFArchive(manifest: manifest, payload: ciphertext)

        return tdfArchive
    }

    // MARK: - TDF Archive Creation

    private func createTDFArchive(manifest: Data, payload: Data) throws -> Data {
        let archivePath = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tdf")

        defer {
            try? FileManager.default.removeItem(at: archivePath)
        }

        // Create ZIP archive using ZIPFoundation
        guard let archive = Archive(url: archivePath, accessMode: .create) else {
            throw TDFProtectionError.archiveCreationFailed
        }

        // Add manifest.json
        try archive.addEntry(
            with: "manifest.json",
            type: .file,
            uncompressedSize: Int64(manifest.count),
            provider: { position, size in
                manifest.subdata(in: Int(position)..<Int(position) + size)
            }
        )

        // Add 0.payload
        try archive.addEntry(
            with: "0.payload",
            type: .file,
            uncompressedSize: Int64(payload.count),
            provider: { position, size in
                payload.subdata(in: Int(position)..<Int(position) + size)
            }
        )

        // Read the archive data
        return try Data(contentsOf: archivePath)
    }
}

/// TDF protection errors
public enum TDFProtectionError: Error, LocalizedError, Sendable {
    case archiveCreationFailed
    case invalidTDFArchive

    public var errorDescription: String? {
        switch self {
        case .archiveCreationFailed:
            "Failed to create TDF ZIP archive"
        case .invalidTDFArchive:
            "Invalid TDF archive format"
        }
    }
}
