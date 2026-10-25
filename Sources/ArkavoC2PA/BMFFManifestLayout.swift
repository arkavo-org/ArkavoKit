import Foundation

/// Where the C2PA manifest box goes in an ISO BMFF file, and the `moov` rewritten to match.
///
/// The spec (A.5.3) puts the box after `ftyp` and before `moov` and the first `mdat`.
/// Writing it there moves everything after `ftyp` down by the box size, so every
/// absolute chunk offset in `moov` (`stco`/`co64`) moves too. An `stco` entry pushed
/// past 4 GiB turns its table into `co64`, which grows `moov`; when `moov` comes
/// before the media, that growth moves the chunks again, so the plan repeats until
/// the offsets settle.
///
/// Only the boxes on the way to the chunk-offset tables are parsed; everything else in
/// `moov` is copied as is. Media in other files (`dref` entries that are not
/// self-contained) is refused, since its chunk offsets are not offsets into this file.
struct BMFFManifestLayout {
    typealias SigningError = C2PAServerSigner.SigningError

    /// One piece of the output file, in order
    enum Segment {
        /// Bytes copied from the input file
        case input(Range<UInt64>)
        /// Bytes that replace a range of the input
        case bytes(Data)
        /// The C2PA manifest box, left out of the content hash
        case manifestBox
    }

    /// Where the manifest box starts: the end of `ftyp`
    let boxOffset: UInt64
    let boxSize: Int
    let segments: [Segment]

    /// Top-level boxes whose absolute offsets this layout does not rewrite
    private static let unsupportedTopLevel: Set<String> = ["moof", "mfra", "sidx", "ssix", "styp", "meta"]
    /// The boxes on the way to the chunk-offset tables and data references, by parent
    private static let pathChildren: [String: Set<String>] = [
        "moov": ["trak"],
        "trak": ["mdia"],
        "mdia": ["minf"],
        "minf": ["dinf", "stbl"],
        "dinf": ["dref"],
        "stbl": ["stco", "co64"],
    ]
    /// Each pass that doesn't settle turns at least one more `stco` table into `co64`
    private static let maxPasses = 64

    /// - Parameters:
    ///   - boxes: the input's top-level boxes, `ftyp` first
    ///   - moov: the bytes of the input's `moov` box
    static func plan(
        boxes: [BMFFBox],
        fileSize: UInt64,
        moov: Data,
        boxSize: Int
    ) throws -> BMFFManifestLayout {
        guard let ftyp = boxes.first, ftyp.type == "ftyp" else {
            throw SigningError.unsupportedContainer("not an ISO BMFF file")
        }
        if let box = boxes.first(where: { unsupportedTopLevel.contains($0.type) }) {
            throw SigningError.unsupportedContainer("top-level '\(box.type)' box is not supported")
        }
        let moovBoxes = boxes.filter { $0.type == "moov" }
        guard moovBoxes.count == 1, let moovBox = moovBoxes.first else {
            throw SigningError.unsupportedContainer("expected exactly one 'moov' box, found \(moovBoxes.count)")
        }
        let moovRange = moovBox.offset..<moovBox.offset + moovBox.size
        let boxOffset = ftyp.offset + ftyp.size

        var growth: UInt64 = 0
        for _ in 0..<maxPasses {
            let shift = { (offset: UInt64) throws -> UInt64 in
                let moved = offset.addingReportingOverflow(UInt64(boxSize))
                let grown = moved.partialValue.addingReportingOverflow(offset >= moovRange.upperBound ? growth : 0)
                guard !moved.overflow, !grown.overflow else {
                    throw SigningError.unsupportedContainer("chunk offset \(offset) is out of range")
                }
                return grown.partialValue
            }
            let rewritten = try rewrite(moov, box: try parseHeader(moov, at: 0, limit: moov.count), shift: shift)
            let newGrowth = UInt64(rewritten.count - moov.count)
            if newGrowth == growth {
                return BMFFManifestLayout(
                    boxOffset: boxOffset,
                    boxSize: boxSize,
                    segments: [
                        .input(0..<boxOffset),
                        .manifestBox,
                        .input(boxOffset..<moovRange.lowerBound),
                        .bytes(rewritten),
                        .input(moovRange.upperBound..<fileSize),
                    ]
                )
            }
            growth = newGrowth
        }
        throw SigningError.unsupportedContainer("chunk offsets did not settle")
    }

    // MARK: - moov rewriting

    private struct Header {
        let type: String
        let range: Range<Int>
        let headerSize: Int
        var body: Range<Int> { range.lowerBound + headerSize..<range.upperBound }
    }

    private static func parseHeader(_ data: Data, at offset: Int, limit: Int) throws -> Header {
        guard offset + 8 <= limit else { throw malformed() }
        var size = UInt64(data.bigEndianInteger(at: offset, width: 4))
        let type = String(decoding: data[data.startIndex + offset + 4..<data.startIndex + offset + 8], as: UTF8.self)
        var headerSize = 8
        if size == 1 {
            guard offset + 16 <= limit else { throw malformed() }
            size = data.bigEndianInteger(at: offset + 8, width: 8)
            headerSize = 16
        }
        guard size >= UInt64(headerSize), size <= UInt64(limit - offset) else { throw malformed() }
        return Header(type: type, range: offset..<offset + Int(size), headerSize: headerSize)
    }

    private static func children(_ data: Data, of box: Header) throws -> [Header] {
        var result: [Header] = []
        var offset = box.body.lowerBound
        while offset < box.body.upperBound {
            let child = try parseHeader(data, at: offset, limit: box.body.upperBound)
            result.append(child)
            offset = child.range.upperBound
        }
        return result
    }

    private static func rewrite(_ data: Data, box: Header, shift: (UInt64) throws -> UInt64) throws -> Data {
        switch box.type {
        case "stco", "co64":
            let width = box.type == "stco" ? 4 : 8
            let start = box.body.lowerBound
            guard box.body.count >= 8 else { throw malformed() }
            let count = Int(data.bigEndianInteger(at: start + 4, width: 4))
            guard box.body.count == 8 + count * width else { throw malformed() }
            let offsets = try (0..<count).map { try shift(data.bigEndianInteger(at: start + 8 + $0 * width, width: width)) }
            let fits32 = width == 4 && offsets.allSatisfy { $0 <= UInt64(UInt32.max) }
            var body = Data(data[data.startIndex + start..<data.startIndex + start + 8]) // version, flags, count
            for offset in offsets {
                if fits32 {
                    body.appendBigEndian(UInt32(offset))
                } else {
                    body.appendBigEndian(offset)
                }
            }
            return header(fits32 ? "stco" : "co64", bodySize: body.count, large: box.headerSize == 16) + body
        case "dref":
            try checkSelfContained(data, dref: box)
            return bytes(data, box)
        default:
            // A container on the path: moov, trak, mdia, minf, dinf or stbl
            let path = pathChildren[box.type] ?? []
            var body = Data()
            for child in try children(data, of: box) {
                if child.type == "mvex" {
                    throw SigningError.unsupportedContainer("fragmented movies are not supported")
                }
                if child.type == "saio" {
                    throw SigningError.unsupportedContainer("'saio' auxiliary offsets are not supported")
                }
                body.append(path.contains(child.type) ? try rewrite(data, box: child, shift: shift) : bytes(data, child))
            }
            return header(box.type, bodySize: body.count, large: box.headerSize == 16) + body
        }
    }

    /// Refuses data references to media in other files. Each `dref` entry is a full box
    /// whose flag 1 means the media is in this file.
    private static func checkSelfContained(_ data: Data, dref: Header) throws {
        guard dref.body.count >= 8 else { throw malformed() }
        var offset = dref.body.lowerBound + 8 // version, flags, entry count
        while offset < dref.body.upperBound {
            let entry = try parseHeader(data, at: offset, limit: dref.body.upperBound)
            guard entry.body.count >= 4 else { throw malformed() }
            if data.bigEndianInteger(at: entry.body.lowerBound, width: 4) & 1 == 0 {
                throw SigningError.unsupportedContainer("media in other files ('\(entry.type)' data reference) is not supported")
            }
            offset = entry.range.upperBound
        }
    }

    private static func bytes(_ data: Data, _ box: Header) -> Data {
        Data(data[data.startIndex + box.range.lowerBound..<data.startIndex + box.range.upperBound])
    }

    private static func header(_ type: String, bodySize: Int, large: Bool) -> Data {
        var data = Data()
        if large || bodySize + 8 > Int(UInt32.max) {
            data.appendBigEndian(UInt32(1))
            data.append(contentsOf: Array(type.utf8))
            data.appendBigEndian(UInt64(bodySize + 16))
        } else {
            data.appendBigEndian(UInt32(bodySize + 8))
            data.append(contentsOf: Array(type.utf8))
        }
        return data
    }

    private static func malformed() -> SigningError {
        .unsupportedContainer("malformed 'moov' box")
    }
}

private extension Data {
    func bigEndianInteger(at offset: Int, width: Int) -> UInt64 {
        self[startIndex + offset..<startIndex + offset + width].reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
