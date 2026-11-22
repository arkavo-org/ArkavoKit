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
    /// Default maximum allowed decompressed size for `manifest.json` (10 MiB).
    public static let defaultMaxManifestBytes: Int = 10 * 1024 * 1024

    /// Default maximum allowed decompressed size for `0.payload` (512 MiB).
    public static let defaultMaxPayloadBytes: Int = 512 * 1024 * 1024

    private struct SizeLimitExceeded: Error {}

    /// Opens a TDF ZIP archive for reading. Throws `invalidArchive` whatever ZIPFoundation's reason.
    private static func openArchive(_ tdfData: Data) throws -> Archive {
        do {
            return try Archive(data: tdfData, accessMode: .read)
        } catch {
            throw TDFArchiveError.invalidArchive("Failed to open ZIP archive")
        }
    }

    /// Safely extracts a single regular-file entry while enforcing an upper bound on
    /// both declared `uncompressedSize` and cumulative streamed bytes.
    private static func extractEntry(
        _ entry: Entry,
        name: String,
        from archive: Archive,
        maxBytes: Int
    ) throws -> Data {
        guard maxBytes >= 0 else {
            throw TDFArchiveError.extractionFailed("\(name): invalid size limit")
        }
        guard entry.type == .file else {
            throw TDFArchiveError.invalidArchive("\(name) is not a regular file")
        }
        guard entry.uncompressedSize <= UInt64(maxBytes) else {
            throw TDFArchiveError.extractionFailed("\(name) exceeds maximum allowed size of \(maxBytes) bytes")
        }

        var extracted = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                if chunk.count > maxBytes - extracted.count {
                    throw SizeLimitExceeded()
                }
                extracted.append(chunk)
            }
        } catch is SizeLimitExceeded {
            throw TDFArchiveError.extractionFailed("\(name) exceeds maximum allowed size of \(maxBytes) bytes")
        } catch {
            throw TDFArchiveError.extractionFailed("\(name): \(error.localizedDescription)")
        }

        return extracted
    }

    /// Extract the manifest from a TDF ZIP archive
    /// - Parameters:
    ///   - tdfData: The TDF archive data (ZIP format)
    ///   - maxBytes: Maximum allowed decompressed manifest size in bytes
    /// - Returns: Parsed TDFManifestLite with encryption metadata
    public static func extractManifest(
        from tdfData: Data,
        maxBytes: Int = defaultMaxManifestBytes
    ) throws -> TDFManifestLite {
        let archive = try openArchive(tdfData)

        guard let manifestEntry = archive["manifest.json"] else {
            throw TDFArchiveError.manifestNotFound
        }

        let manifestData = try extractEntry(manifestEntry, name: "manifest.json", from: archive, maxBytes: maxBytes)

        guard let json = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw TDFArchiveError.invalidArchive("manifest.json is not valid JSON")
        }

        return try TDFManifestLite.from(manifestJSON: json)
    }

    /// Extract the encrypted payload from a TDF ZIP archive
    /// - Parameters:
    ///   - tdfData: The TDF archive data (ZIP format)
    ///   - maxBytes: Maximum allowed decompressed payload size in bytes
    /// - Returns: The encrypted payload data (AES-128-CBC encrypted content)
    public static func extractPayload(
        from tdfData: Data,
        maxBytes: Int = defaultMaxPayloadBytes
    ) throws -> Data {
        let archive = try openArchive(tdfData)

        guard let payloadEntry = archive["0.payload"] else {
            throw TDFArchiveError.payloadNotFound
        }

        return try extractEntry(payloadEntry, name: "0.payload", from: archive, maxBytes: maxBytes)
    }

    /// Extract both manifest and payload from a TDF ZIP archive
    /// - Parameters:
    ///   - tdfData: The TDF archive data (ZIP format)
    ///   - maxManifestBytes: Maximum allowed decompressed manifest size in bytes
    ///   - maxPayloadBytes: Maximum allowed decompressed payload size in bytes
    /// - Returns: Tuple containing the parsed manifest and encrypted payload
    public static func extractAll(
        from tdfData: Data,
        maxManifestBytes: Int = defaultMaxManifestBytes,
        maxPayloadBytes: Int = defaultMaxPayloadBytes
    ) throws -> (manifest: TDFManifestLite, payload: Data) {
        let archive = try openArchive(tdfData)

        // Extract manifest
        guard let manifestEntry = archive["manifest.json"] else {
            throw TDFArchiveError.manifestNotFound
        }

        let manifestData = try extractEntry(manifestEntry, name: "manifest.json", from: archive, maxBytes: maxManifestBytes)

        guard let json = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw TDFArchiveError.invalidArchive("manifest.json is not valid JSON")
        }

        let manifest = try TDFManifestLite.from(manifestJSON: json)

        // Extract payload
        guard let payloadEntry = archive["0.payload"] else {
            throw TDFArchiveError.payloadNotFound
        }

        let payloadData = try extractEntry(payloadEntry, name: "0.payload", from: archive, maxBytes: maxPayloadBytes)

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
