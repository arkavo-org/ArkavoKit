import Foundation
import ZIPFoundation

// MARK: - TDFArchiveError

/// Errors that can occur when reading TDF archives
public enum TDFArchiveError: Error, LocalizedError, Sendable {
    case manifestNotFound
    case payloadNotFound
    case invalidArchive(String)
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            "manifest.json not found in TDF archive"
        case .payloadNotFound:
            "0.payload not found in TDF archive"
        case let .invalidArchive(reason):
            "Invalid TDF archive: \(reason)"
        case let .extractionFailed(reason):
            "Failed to extract from archive: \(reason)"
        }
    }
}

// MARK: - TDFArchiveReader

/// Reads and extracts components from TDF3 ZIP archives
///
/// TDF3 archives contain:
/// - `manifest.json`: Encryption metadata (KAS URL, wrapped key, IV, algorithm)
/// - `0.payload`: The encrypted content (AES-128-CBC encrypted video/audio)
public struct TDFArchiveReader: Sendable {
    /// Extract the manifest from a TDF ZIP archive
    /// - Parameter tdfData: The TDF archive data (ZIP format)
    /// - Returns: Parsed TDFManifestLite with encryption metadata
    public static func extractManifest(from tdfData: Data) throws -> TDFManifestLite {
        guard let archive = Archive(data: tdfData, accessMode: .read) else {
            throw TDFArchiveError.invalidArchive("Failed to open ZIP archive")
        }

        guard let manifestEntry = archive["manifest.json"] else {
            throw TDFArchiveError.manifestNotFound
        }

        var manifestData = Data()
        do {
            _ = try archive.extract(manifestEntry) { data in
                manifestData.append(data)
            }
        } catch {
            throw TDFArchiveError.extractionFailed("manifest.json: \(error.localizedDescription)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw TDFArchiveError.invalidArchive("manifest.json is not valid JSON")
        }

        return try TDFManifestLite.from(manifestJSON: json)
    }

    /// Extract the encrypted payload from a TDF ZIP archive
    /// - Parameter tdfData: The TDF archive data (ZIP format)
    /// - Returns: The encrypted payload data (AES-128-CBC encrypted content)
    public static func extractPayload(from tdfData: Data) throws -> Data {
        guard let archive = Archive(data: tdfData, accessMode: .read) else {
            throw TDFArchiveError.invalidArchive("Failed to open ZIP archive")
        }

        guard let payloadEntry = archive["0.payload"] else {
            throw TDFArchiveError.payloadNotFound
        }

        var payloadData = Data()
        do {
            _ = try archive.extract(payloadEntry) { data in
                payloadData.append(data)
            }
        } catch {
            throw TDFArchiveError.extractionFailed("0.payload: \(error.localizedDescription)")
        }

        return payloadData
    }

    /// Extract both manifest and payload from a TDF ZIP archive
    /// - Parameter tdfData: The TDF archive data (ZIP format)
    /// - Returns: Tuple containing the parsed manifest and encrypted payload
    public static func extractAll(from tdfData: Data) throws -> (manifest: TDFManifestLite, payload: Data) {
        guard let archive = Archive(data: tdfData, accessMode: .read) else {
            throw TDFArchiveError.invalidArchive("Failed to open ZIP archive")
        }

        // Extract manifest
        guard let manifestEntry = archive["manifest.json"] else {
            throw TDFArchiveError.manifestNotFound
        }

        var manifestData = Data()
        do {
            _ = try archive.extract(manifestEntry) { data in
                manifestData.append(data)
            }
        } catch {
            throw TDFArchiveError.extractionFailed("manifest.json: \(error.localizedDescription)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw TDFArchiveError.invalidArchive("manifest.json is not valid JSON")
        }

        let manifest = try TDFManifestLite.from(manifestJSON: json)

        // Extract payload
        guard let payloadEntry = archive["0.payload"] else {
            throw TDFArchiveError.payloadNotFound
        }

        var payloadData = Data()
        do {
            _ = try archive.extract(payloadEntry) { data in
                payloadData.append(data)
            }
        } catch {
            throw TDFArchiveError.extractionFailed("0.payload: \(error.localizedDescription)")
        }

        return (manifest, payloadData)
    }

    /// Write the encrypted payload to a temporary file for FairPlay playback
    /// - Parameters:
    ///   - payload: The encrypted payload data
    ///   - fileExtension: File extension (default: "ts" for MPEG-TS)
    /// - Returns: URL to the temporary file
    public static func writePayloadToTempFile(
        _ payload: Data,
        fileExtension: String = "ts"
    ) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        try payload.write(to: tempURL)
        return tempURL
    }
}
