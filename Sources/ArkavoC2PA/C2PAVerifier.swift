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
    public let actions: [C2PAProvenanceAction]

    public init(
        creator: String? = nil,
        signedAt: Date? = nil,
        signedAtText: String? = nil,
        aiGenerated: Bool? = nil,
        actions: [C2PAProvenanceAction] = []
    ) {
        self.creator = creator
        self.signedAt = signedAt
        self.signedAtText = signedAtText
        self.aiGenerated = aiGenerated
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
    private let session: URLSession

    public init(serverURL: URL = C2PASigningService.defaultServerURL, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.session = session
    }

    /// Largest manifest box `verify` reads into memory. The signer writes at most
    /// `C2PAManifestBox.maxSize`; manifests from other signers can carry thumbnails.
    static let maxBoxSize: UInt64 = 16 * 1024 * 1024

    /// Whether the file has a C2PA manifest box. Reads only box headers; no network.
    public static func hasManifest(_ file: URL) throws -> Bool {
        try BMFFBox.topLevelBoxes(in: file)?.contains(where: \.isC2PAManifest) ?? false
    }

    /// Verifies the file's manifest with the signing server. Only the manifest and a
    /// SHA-256 of the rest of the file are sent. A file without a manifest box, or
    /// with a box that holds no manifest store, is answered without a network call.
    public func verify(_ file: URL) async throws -> C2PAVerification {
        guard let box = try BMFFBox.topLevelBoxes(in: file)?.first(where: \.isC2PAManifest) else {
            return .noManifest
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let boxRange = box.offset..<(box.size == 0 ? fileSize : box.offset + box.size)

        guard UInt64(boxRange.count) <= Self.maxBoxSize else {
            return Self.malformed("the C2PA manifest box is \(boxRange.count) bytes")
        }
        try handle.seek(toOffset: boxRange.lowerBound)
        guard let boxData = try handle.read(upToCount: Int(boxRange.count)),
              let manifestStore = Self.manifestStore(inBox: boxData) else {
            return Self.malformed("the C2PA box holds no manifest store")
        }

        let contentHash = try Self.sha256Hex(of: handle, size: fileSize, excluding: boxRange)
        return try await validate(manifestStore: manifestStore, contentHash: contentHash)
    }

    // MARK: - Box

    /// The manifest store in a C2PA box: the JUMBF after the box header, purpose
    /// `manifest` and Merkle offset, cut to the store's own size because the box may
    /// be zero-padded (spec A.5.3). Nil when the box doesn't hold one.
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

    private func validate(manifestStore: Data, contentHash: String) async throws -> C2PAVerification {
        var request = URLRequest(url: serverURL.appendingPathComponent("c2pa/v1/validate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "manifest": manifestStore.base64EncodedString(),
            "content_hash": contentHash,
        ])

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

    /// arkavo-rs `C2paValidateResponse`
    private struct ValidateResponse: Decodable {
        let valid: Bool
        let errors: [String]
        let creator: String?
        let provenanceChain: [Entry]?
        let aiGenerated: Bool?
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
            case signedAt = "signed_at"
        }
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }
}
