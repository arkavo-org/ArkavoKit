import CryptoKit
import Foundation

/// One action in a manifest's provenance chain, as `/c2pa/v1/validate` reports it
public struct C2PAProvenanceAction: Sendable, Equatable {
    /// The action without its `c2pa.` prefix, e.g. `created`
    public let action: String
    public let actor: String
    /// The action's `when`, as written in the manifest
    public let timestamp: String?
    public let software: String?

    public init(action: String, actor: String, timestamp: String? = nil, software: String? = nil) {
        self.action = action
        self.actor = actor
        self.timestamp = timestamp
        self.software = software
    }
}

/// What a manifest says about the file, whether or not it verified
public struct C2PAProvenance: Sendable, Equatable {
    public let creator: String?
    /// When the manifest was signed, from its trusted timestamp; nil without one
    public let signedAt: Date?
    /// `signedAt` as the server reported it, kept in case it doesn't parse
    public let signedAtText: String?
    public let aiGenerated: Bool?
    /// The `c2pa.created` action's source type; nil when absent or not a term this kit lists
    public let digitalSourceType: C2PADigitalSourceType?
    public let actions: [C2PAProvenanceAction]

    public init(
        creator: String? = nil,
        signedAt: Date? = nil,
        signedAtText: String? = nil,
        aiGenerated: Bool? = nil,
        digitalSourceType: C2PADigitalSourceType? = nil,
        actions: [C2PAProvenanceAction] = []
    ) {
        self.creator = creator
        self.signedAt = signedAt
        self.signedAtText = signedAtText
        self.aiGenerated = aiGenerated
        self.digitalSourceType = digitalSourceType
        self.actions = actions
    }
}

/// The outcome of verifying a file's C2PA manifest
public enum C2PAVerification: Sendable, Equatable {
    /// The file has no C2PA manifest box
    case noManifest
    /// The manifest is signed by a trusted certificate and its hash matches the file
    case valid(C2PAProvenance)
    /// The file has a manifest that doesn't verify: the media changed since signing,
    /// the signer isn't trusted, or the box is malformed
    case invalid(errors: [String], provenance: C2PAProvenance)
}

/// Reads back what `C2PAServerSigner` wrote. `hasManifest` is a local check of the
/// file's box headers; `verify` sends the manifest and the hash of the rest of the
/// file to the arkavo-rs `POST /c2pa/v1/validate`, which needs no sign-in.
public struct C2PAVerifier: Sendable {
    public let serverURL: URL
    let session: URLSession

    public init(
        serverURL: URL = C2PASigningService.defaultServerURL,
        session: URLSession = C2PASigningService.defaultSession
    ) {
        self.serverURL = serverURL
        self.session = session
    }

    /// Largest manifest box `verify` reads into memory. The signer writes at most
    /// `C2PAManifestBox.maxSize`; manifests from other signers can carry thumbnails.
    static let maxBoxSize: UInt64 = 16 * 1024 * 1024

    /// Whether the file has a C2PA manifest box, even if the file is damaged after it.
    /// Reads only box headers; no network.
    public static func hasManifest(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try BMFFBox.scan(handle).boxes.contains(where: \.isC2PAManifest)
    }

    /// Verifies the file's manifest with the signing server. Only the manifest and a
    /// SHA-256 of the rest of the file are sent.
    ///
    /// The hash covers the bytes outside the box wherever the box is, so a box that
    /// grew or moved would leave it unchanged while the media offsets point at other
    /// bytes. Only the box arks signs is accepted: right after `ftyp`, holding exactly
    /// the manifest store (arks negotiates the box to the manifest's size). Anything
    /// else, a damaged file, or a box with no manifest store is `.invalid` without a
    /// network call. The box's range is also sent, so the server can check it is the
    /// exclusion the manifest was signed with.
    public func verify(_ file: URL) async throws -> C2PAVerification {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let scan = try BMFFBox.scan(handle)
        guard let box = scan.boxes.first(where: \.isC2PAManifest) else {
            return .noManifest
        }
        guard scan.isComplete else {
            return Self.malformed("the file is damaged: its boxes don't end at the end of the file")
        }
        guard scan.boxes.count > 1, scan.boxes[0].type == "ftyp", scan.boxes[1] == box, box.size != 0 else {
            return Self.malformed("the C2PA manifest box is not right after ftyp")
        }
        guard box.size <= Self.maxBoxSize else {
            return Self.malformed("the C2PA manifest box is \(box.size) bytes")
        }
        try handle.seek(toOffset: box.offset)
        guard let boxData = try handle.read(upToCount: Int(box.size)), boxData.count == Int(box.size),
              let manifestStore = Self.manifestStore(inBox: boxData) else {
            return Self.malformed("the C2PA box holds no manifest store")
        }
        guard boxData == C2PAManifestBox.make(jumbf: manifestStore) else {
            return Self.malformed("the C2PA box is not the size it was signed at")
        }

        let boxRange = box.offset..<box.offset + box.size
        let contentHash = try Self.sha256Hex(of: handle, size: scan.fileSize, excluding: boxRange)
        return try await validate(manifestStore: manifestStore, contentHash: contentHash, boxRange: boxRange)
    }

    // MARK: - Box

    /// The manifest store in a C2PA box: the JUMBF after the box header, purpose
    /// `manifest` and Merkle offset, cut to the store's own size. `verify` then requires
    /// the box to hold nothing else. Nil when the box doesn't hold one.
    static func manifestStore(inBox box: Data) -> Data? {
        let bytes = [UInt8](box)
        var offset = 8
        guard bytes.count >= 8 else { return nil }
        if bytes[0..<4].elementsEqual([0, 0, 0, 1]) { offset = 16 }  // 64-bit box size
        offset += 16 + 4  // extended type, version and flags
        guard let terminator = bytes[min(offset, bytes.count)...].firstIndex(of: 0),
              String(decoding: bytes[offset..<terminator], as: UTF8.self) == "manifest" else {
            return nil
        }
        offset = terminator + 1 + 8  // purpose and its NUL, then the Merkle offset
        guard offset + 8 <= bytes.count else { return nil }

        var size = bytes[offset..<offset + 4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        if size == 1, offset + 16 <= bytes.count {
            size = bytes[offset + 8..<offset + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        guard size <= UInt64(bytes.count - offset) else { return nil }
        let store = Data(bytes[offset..<offset + Int(size)])
        return C2PASigningService.isManifestStore(store) ? store : nil
    }

    private static func malformed(_ reason: String) -> C2PAVerification {
        .invalid(errors: [reason], provenance: C2PAProvenance())
    }

    /// SHA-256 of the file without `excluded`: the content hash the signer sent
    private static func sha256Hex(of handle: FileHandle, size: UInt64, excluding excluded: Range<UInt64>) throws -> String {
        var hasher = SHA256()
        for range in [0..<excluded.lowerBound, excluded.upperBound..<size] where !range.isEmpty {
            try handle.seek(toOffset: range.lowerBound)
            var remaining = range.upperBound - range.lowerBound
            while remaining > 0 {
                let chunk = try autoreleasepool {
                    try handle.read(upToCount: Swift.min(C2PAServerSigner.readChunkSize, Int(remaining)))
                }
                guard let chunk, !chunk.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                hasher.update(data: chunk)
                remaining -= UInt64(chunk.count)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Server

    /// The box range goes with the request so the server can check it is the exclusion the
    /// manifest was signed with (arkavo-rs#123). A store that grew inside the box passes
    /// the local checks above; only the signed exclusion catches it.
    private func validate(manifestStore: Data, contentHash: String, boxRange: Range<UInt64>) async throws -> C2PAVerification {
        var request = URLRequest(url: serverURL.appendingPathComponent("c2pa/v1/validate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ValidateRequest(
            manifest: manifestStore.base64EncodedString(),
            contentHash: contentHash,
            exclusionRanges: [C2PAExclusionRange(start: boxRange.lowerBound, end: boxRange.upperBound, boxType: "uuid")]
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw C2PASigningService.ServiceError.invalidResponse("not an HTTP response")
        }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? String(decoding: data, as: UTF8.self)
            throw C2PASigningService.ServiceError.server(statusCode: http.statusCode, message: message)
        }
        let body: ValidateResponse
        do {
            body = try JSONDecoder().decode(ValidateResponse.self, from: data)
        } catch {
            throw C2PASigningService.ServiceError.invalidResponse("validate response: \(error.localizedDescription)")
        }

        let provenance = C2PAProvenance(
            creator: body.creator,
            signedAt: body.signedAt.flatMap(Self.date(rfc3339:)),
            signedAtText: body.signedAt,
            aiGenerated: body.aiGenerated,
            digitalSourceType: body.digitalSourceType.flatMap(C2PADigitalSourceType.init(rawValue:)),
            actions: (body.provenanceChain ?? []).map {
                C2PAProvenanceAction(action: $0.action, actor: $0.actor, timestamp: $0.timestamp, software: $0.software)
            }
        )
        return body.valid ? .valid(provenance) : .invalid(errors: body.errors, provenance: provenance)
    }

    private static func date(rfc3339 text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// arkavo-rs `C2paValidateRequest`
    private struct ValidateRequest: Encodable {
        let manifest: String
        let contentHash: String
        let exclusionRanges: [C2PAExclusionRange]

        enum CodingKeys: String, CodingKey {
            case manifest
            case contentHash = "content_hash"
            case exclusionRanges = "exclusion_ranges"
        }
    }

    /// arkavo-rs `C2paValidateResponse`
    private struct ValidateResponse: Decodable {
        let valid: Bool
        let errors: [String]
        let creator: String?
        let provenanceChain: [Entry]?
        let aiGenerated: Bool?
        let digitalSourceType: String?
        let signedAt: String?

        struct Entry: Decodable {
            let action: String
            let actor: String
            let timestamp: String?
            let software: String?
        }

        enum CodingKeys: String, CodingKey {
            case valid
            case errors
            case creator
            case provenanceChain = "provenance_chain"
            case aiGenerated = "ai_generated"
            case digitalSourceType = "digital_source_type"
            case signedAt = "signed_at"
        }
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }
}
