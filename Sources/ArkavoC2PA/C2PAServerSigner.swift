import CryptoKit
import Foundation

/// Where a server-signed manifest was embedded
public struct C2PAEmbeddedManifest: Sendable {
    /// Hex SHA-256 of the signed file with the manifest box left out
    public let contentHash: String
    /// Byte range of the C2PA manifest box in the output file
    public let manifestRange: Range<UInt64>
    /// Sign requests needed before the manifest fit its box
    public let requestCount: Int
}

/// Signs MOV, MP4 and M4A files with a C2PA manifest from the arkavo-rs signing server.
///
/// The manifest box goes right after `ftyp`, as the spec requires (A.5.3: before
/// `moov` and the first `mdat`). Everything after it moves down by the box size, so
/// the chunk offsets in `moov` are rewritten to match (`BMFFManifestLayout`). The
/// content hash covers the output file except the box, which is the manifest's only
/// hash exclusion.
///
/// The box has a fixed reserved size and the manifest is zero-padded to fill it, so
/// the media moves once and, with a server that accepts padding, one sign request
/// is enough. A server that wants a different box size answers 422 with the length
/// it needs (`ServiceError.exclusionLengthMismatch`); the signer then lays the file
/// out again with that size, hashes it again and asks once more. A manifest larger
/// than the box gets the same treatment.
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

    /// Room for the manifest store: a signed manifest with the Arkavo certificate
    /// chain and an RFC 3161 timestamp is about 20 KiB. Kept under 64 KiB so the box
    /// end stays below 65,536 like the exact size does: if a server without padding
    /// support asks for the exact length, the CBOR width of the range end doesn't
    /// change between the two requests, so the second one fits.
    static let defaultReservation = 48 * 1024
    static let maxRequests = 4
    static let readChunkSize = 1024 * 1024

    private let signManifest: SignManifest
    private let reservation: Int

    public init(service: C2PASigningService = C2PASigningService()) {
        self.signManifest = { try await service.signManifest($0) }
        self.reservation = Self.defaultReservation
    }

    init(reservation: Int = defaultReservation, signManifest: @escaping SignManifest) {
        self.signManifest = signManifest
        self.reservation = reservation
    }

    /// Writes `inputFile` with its C2PA manifest box to `outputFile`, which must not exist
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
        let (boxes, fileSize) = try Self.topLevelBoxes(of: inputFile)
        let moov = try Self.read(inputFile, ranges: boxes.filter { $0.type == "moov" }.map { $0.offset..<$0.offset + $0.size })

        var boxSize = reservation
        for attempt in 1...Self.maxRequests {
            let layout = try BMFFManifestLayout.plan(boxes: boxes, fileSize: fileSize, moov: moov, boxSize: boxSize)
            let contentHash = try Self.sha256Hex(of: inputFile, layout: layout)
            let range = C2PAExclusionRange(
                start: layout.boxOffset,
                end: layout.boxOffset + UInt64(boxSize),
                boxType: "uuid"
            )
            let jumbf: Data
            do {
                jumbf = try await signManifest(C2PASignRequest(
                    contentHash: contentHash,
                    exclusionRanges: [range],
                    containerFormat: format,
                    metadata: metadata
                ))
            } catch C2PASigningService.ServiceError.exclusionLengthMismatch(let requiredLength) {
                boxSize = try Self.checkedBoxSize(requiredLength, from: "required_exclusion_length")
                continue
            }
            let needed = try Self.checkedBoxSize(C2PAManifestBox.headerSize + jumbf.count, from: "signed manifest size")
            guard needed <= boxSize else {
                boxSize = needed
                continue
            }
            try Self.write(
                inputFile,
                layout: layout,
                box: C2PAManifestBox.make(jumbf: jumbf, size: boxSize),
                to: outputFile
            )
            return C2PAEmbeddedManifest(
                contentHash: contentHash,
                manifestRange: range.start..<range.end,
                requestCount: attempt
            )
        }
        throw SigningError.manifestSizeDidNotSettle(attempts: Self.maxRequests)
    }

    /// A box size that came from the server, refused unless it can hold the box header
    /// and stays within `C2PAManifestBox.maxSize`
    private static func checkedBoxSize(_ size: Int, from source: String) throws -> Int {
        guard (C2PAManifestBox.headerSize...C2PAManifestBox.maxSize).contains(size) else {
            throw C2PASigningService.ServiceError.invalidResponse("\(source) \(size) is out of range")
        }
        return size
    }

    /// The input's top-level boxes, checked for a manifest box to be written into
    private static func topLevelBoxes(of url: URL) throws -> ([BMFFBox], UInt64) {
        guard let boxes = try BMFFBox.topLevelBoxes(in: url), boxes.first?.type == "ftyp" else {
            throw SigningError.unsupportedContainer("not an ISO BMFF file")
        }
        if boxes.contains(where: \.isC2PAManifest) {
            throw SigningError.alreadySigned
        }
        guard let last = boxes.last, last.size != 0 else {
            throw SigningError.unsupportedContainer("the last box runs to end of file")
        }
        return (boxes, last.offset + last.size)
    }

    private static func read(_ url: URL, ranges: [Range<UInt64>]) throws -> Data {
        guard ranges.count == 1, let range = ranges.first else {
            throw SigningError.unsupportedContainer("expected exactly one 'moov' box, found \(ranges.count)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: range.lowerBound)
        guard let data = try handle.read(upToCount: Int(range.count)), data.count == range.count else {
            throw SigningError.unsupportedContainer("truncated 'moov' box")
        }
        return data
    }

    /// SHA-256 of the output the layout describes, without the manifest box
    private static func sha256Hex(of input: URL, layout: BMFFManifestLayout) throws -> String {
        var hasher = SHA256()
        try stream(input, layout: layout, box: nil) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the output to a temporary file next to `output`, then moves it into place
    private static func write(_ input: URL, layout: BMFFManifestLayout, box: Data, to output: URL) throws {
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).c2pa-tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try stream(input, layout: layout, box: box) { try handle.write(contentsOf: $0) }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Feeds the layout's bytes in order; the manifest box only when `box` is given
    private static func stream(
        _ input: URL,
        layout: BMFFManifestLayout,
        box: Data?,
        body: (Data) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        for segment in layout.segments {
            switch segment {
            case .manifestBox:
                if let box { try body(box) }
            case .bytes(let data):
                try body(data)
            case .input(let range):
                try handle.seek(toOffset: range.lowerBound)
                var remaining = range.upperBound - range.lowerBound
                while remaining > 0 {
                    let chunk = try autoreleasepool {
                        try handle.read(upToCount: Swift.min(readChunkSize, Int(remaining)))
                    }
                    guard let chunk, !chunk.isEmpty else {
                        throw SigningError.unsupportedContainer("the input file changed while signing")
                    }
                    try body(chunk)
                    remaining -= UInt64(chunk.count)
                }
            }
        }
    }
}
