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

    static func make(jumbf: Data) -> Data {
        var box = Data(capacity: headerSize + jumbf.count)
        withUnsafeBytes(of: UInt32(headerSize + jumbf.count).bigEndian) { box.append(contentsOf: $0) }
        box.append(contentsOf: Array("uuid".utf8))
        box.append(c2paUUID)
        box.append(contentsOf: [0, 0, 0, 0])
        box.append(contentsOf: Array("manifest".utf8) + [0])
        box.append(contentsOf: [UInt8](repeating: 0, count: 8))
        box.append(jumbf)
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

    /// Reads the top-level box headers. Returns nil when the file does not parse
    /// as a sequence of boxes that ends exactly at end of file.
    static func topLevelBoxes(in url: URL) throws -> [BMFFBox]? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        var boxes: [BMFFBox] = []
        var offset: UInt64 = 0
        while offset < fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { return nil }
            var size = UInt64(header.bigEndianUInt32(at: 0))
            guard let type = String(bytes: header[4..<8], encoding: .ascii) else { return nil }
            var headerLength: UInt64 = 8
            if size == 1 {
                guard let large = try handle.read(upToCount: 8), large.count == 8 else { return nil }
                size = large.bigEndianUInt64(at: 0)
                headerLength = 16
            }
            var userType: Data?
            if type == "uuid" {
                guard let extended = try handle.read(upToCount: 16), extended.count == 16 else { return nil }
                userType = extended
                headerLength += 16
            }
            if size == 0 {
                boxes.append(BMFFBox(type: type, offset: offset, size: 0, userType: userType))
                return boxes
            }
            guard size >= headerLength, size <= fileSize - offset else { return nil }
            boxes.append(BMFFBox(type: type, offset: offset, size: size, userType: userType))
            offset += size
        }
        return boxes
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
