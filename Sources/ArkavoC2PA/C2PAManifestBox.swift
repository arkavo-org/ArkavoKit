import Foundation

/// The C2PA manifest box for ISO BMFF files (MOV, MP4, M4A): a top-level
/// `uuid` box with the C2PA extended type whose payload is the JUMBF manifest store.
enum C2PAManifestBox {
    static let c2paUUID = Data([
        0xD8, 0xFE, 0xC3, 0xD6, 0x1B, 0x0E, 0x48, 0x3C,
        0x92, 0x97, 0x58, 0x28, 0x87, 0x7E, 0xC4, 0x81,
    ])

    /// size + `uuid` + extended type + version/flags + "manifest\0" + merkle offset
    static let headerSize = 4 + 4 + 16 + 4 + 9 + 8

    /// Largest box the signer writes. A signed manifest with its certificate chain and
    /// timestamp is about 20 KiB; a size from the server beyond this is refused rather
    /// than shifting the media by it.
    static let maxSize = 1024 * 1024

    /// A box of `size` bytes (default: just large enough). The spec (A.5.3) allows
    /// unused zero padding after the manifest store inside the box.
    static func make(jumbf: Data, size: Int? = nil) -> Data {
        let size = size ?? headerSize + jumbf.count
        precondition(size >= headerSize + jumbf.count, "manifest larger than its box")
        var box = Data(capacity: size)
        withUnsafeBytes(of: UInt32(size).bigEndian) { box.append(contentsOf: $0) }
        box.append(contentsOf: Array("uuid".utf8))
        box.append(c2paUUID)
        box.append(contentsOf: [0, 0, 0, 0])
        box.append(contentsOf: Array("manifest".utf8) + [0])
        box.append(contentsOf: [UInt8](repeating: 0, count: 8))
        box.append(jumbf)
        box.append(Data(count: size - box.count))
        return box
    }
}

/// Top-level box of an ISO BMFF file
struct BMFFBox: Equatable {
    let type: String
    let offset: UInt64
    /// 0 means the box runs to the end of the file
    let size: UInt64
    /// Extended type of a `uuid` box
    let userType: Data?

    var isC2PAManifest: Bool {
        type == "uuid" && userType == C2PAManifestBox.c2paUUID
    }

    /// The top-level boxes of a file, read up to the first one that doesn't parse
    struct Scan {
        let boxes: [BMFFBox]
        let fileSize: UInt64
        /// Whether the boxes run exactly to the end of the file
        let isComplete: Bool
    }

    /// Reads the top-level box headers. Returns nil when the file does not parse
    /// as a sequence of boxes that ends exactly at end of file.
    static func topLevelBoxes(in url: URL) throws -> [BMFFBox]? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let scan = try scan(handle)
        return scan.isComplete ? scan.boxes : nil
    }

    /// Reads the top-level box headers through `handle`, keeping the boxes before any
    /// damage, so a damaged file still shows what it held
    static func scan(_ handle: FileHandle) throws -> Scan {
        let fileSize = try handle.seekToEnd()

        var boxes: [BMFFBox] = []
        var offset: UInt64 = 0
        let damaged = { Scan(boxes: boxes, fileSize: fileSize, isComplete: false) }
        while offset < fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { return damaged() }
            var size = UInt64(header.bigEndianUInt32(at: 0))
            guard let type = String(bytes: header[4..<8], encoding: .ascii) else { return damaged() }
            var headerLength: UInt64 = 8
            if size == 1 {
                guard let large = try handle.read(upToCount: 8), large.count == 8 else { return damaged() }
                size = large.bigEndianUInt64(at: 0)
                headerLength = 16
            }
            var userType: Data?
            if type == "uuid" {
                guard let extended = try handle.read(upToCount: 16), extended.count == 16 else { return damaged() }
                userType = extended
                headerLength += 16
            }
            if size == 0 {
                boxes.append(BMFFBox(type: type, offset: offset, size: 0, userType: userType))
                return Scan(boxes: boxes, fileSize: fileSize, isComplete: true)
            }
            guard size >= headerLength, size <= fileSize - offset else { return damaged() }
            boxes.append(BMFFBox(type: type, offset: offset, size: size, userType: userType))
            offset += size
        }
        return Scan(boxes: boxes, fileSize: fileSize, isComplete: true)
    }
}

private extension Data {
    func bigEndianUInt32(at index: Int) -> UInt32 {
        self[startIndex + index..<startIndex + index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func bigEndianUInt64(at index: Int) -> UInt64 {
        self[startIndex + index..<startIndex + index + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
