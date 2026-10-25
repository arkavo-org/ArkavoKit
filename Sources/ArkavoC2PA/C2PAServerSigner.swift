import CryptoKit
import Foundation

/// Where a server-signed manifest was embedded
public struct C2PAEmbeddedManifest: Sendable {
    /// Hex SHA-256 of the asset with the manifest box left out
    public let contentHash: String
    /// Byte range of the appended C2PA manifest box in the output file
    public let manifestRange: Range<UInt64>
    /// Sign requests needed before the manifest fit its reserved range
    public let requestCount: Int
}

/// Signs MOV, MP4 and M4A files with a C2PA manifest from the arkavo-rs signing server.
///
/// The manifest box is appended at the end of the file. Inserting it after `ftyp`
/// (where c2pa-rs writes it) would shift every `stco`/`co64` chunk offset and break
/// playback unless the sample tables were rewritten. At the end, the original bytes
/// are untouched, so the content hash is the SHA-256 of the input file and the box
/// is the manifest's only hash exclusion.
///
/// The exclusion range must be the exact size of the box, which is only known once
/// the server has signed. The signer therefore requests a manifest for a reserved
/// size, and repeats with the size the server reports until the two match (normally
/// on the second request, or the third when the range end crosses a CBOR integer
/// width such as 65,536). The server either answers 422 with the length it needs
/// (`ServiceError.exclusionLengthMismatch`) or, if it predates that check, returns a
/// manifest of a different size. If the end sits within a few bytes of such a
/// boundary there may be no size that fits, and signing fails with
/// `manifestSizeDidNotSettle`.
public struct C2PAServerSigner: Sendable {
    typealias SignManifest = @Sendable (C2PASignRequest) async throws -> Data

    public enum SigningError: Error, LocalizedError {
        case unsupportedContainer(String)
        case alreadySigned
        case outputExists(URL)
        case manifestSizeDidNotSettle(attempts: Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedContainer(let reason):
                return "Cannot embed a C2PA manifest: \(reason)"
            case .alreadySigned:
                return "The file already contains a C2PA manifest"
            case .outputExists(let url):
                return "Output file already exists: \(url.path)"
            case .manifestSizeDidNotSettle(let attempts):
                return "The signed manifest size changed on each of \(attempts) requests"
            }
        }
    }

    static let initialReservation = 16 * 1024
    static let maxRequests = 4
    static let hashChunkSize = 1024 * 1024

    private let signManifest: SignManifest

    public init(service: C2PASigningService = C2PASigningService()) {
        self.signManifest = { try await service.signManifest($0) }
    }

    init(signManifest: @escaping SignManifest) {
        self.signManifest = signManifest
    }

    /// Writes `inputFile` plus its C2PA manifest box to `outputFile`, which must not exist
    public func sign(
        inputFile: URL,
        outputFile: URL,
        metadata: C2PASigningMetadata
    ) async throws -> C2PAEmbeddedManifest {
        guard let format = C2PAContainerFormat(fileExtension: inputFile.pathExtension) else {
            throw SigningError.unsupportedContainer("unsupported file type .\(inputFile.pathExtension)")
        }
        guard !FileManager.default.fileExists(atPath: outputFile.path) else {
            throw SigningError.outputExists(outputFile)
        }
        let fileSize = try Self.appendOffset(for: inputFile)
        let contentHash = try Self.sha256Hex(of: inputFile)

        var reserved = Self.initialReservation
        for attempt in 1...Self.maxRequests {
            let range = C2PAExclusionRange(start: fileSize, end: fileSize + UInt64(reserved), boxType: "uuid")
            let jumbf: Data
            do {
                jumbf = try await signManifest(C2PASignRequest(
                    contentHash: contentHash,
                    exclusionRanges: [range],
                    containerFormat: format,
                    metadata: metadata
                ))
            } catch C2PASigningService.ServiceError.exclusionLengthMismatch(let requiredLength) {
                reserved = requiredLength
                continue
            }
            let box = C2PAManifestBox.make(jumbf: jumbf)
            if box.count == reserved {
                try Self.write(inputFile, appending: box, to: outputFile)
                return C2PAEmbeddedManifest(
                    contentHash: contentHash,
                    manifestRange: range.start..<range.end,
                    requestCount: attempt
                )
            }
            reserved = box.count
        }
        throw SigningError.manifestSizeDidNotSettle(attempts: Self.maxRequests)
    }

    /// Checks the file can take an appended manifest box and returns its size
    private static func appendOffset(for url: URL) throws -> UInt64 {
        guard let boxes = try BMFFBox.topLevelBoxes(in: url), boxes.first?.type == "ftyp" else {
            throw SigningError.unsupportedContainer("not an ISO BMFF file")
        }
        if boxes.contains(where: \.isC2PAManifest) {
            throw SigningError.alreadySigned
        }
        guard let last = boxes.last, last.size != 0 else {
            throw SigningError.unsupportedContainer("the last box runs to end of file")
        }
        return last.offset + last.size
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: hashChunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ input: URL, appending box: Data, to output: URL) throws {
        try FileManager.default.copyItem(at: input, to: output)
        do {
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: box)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
