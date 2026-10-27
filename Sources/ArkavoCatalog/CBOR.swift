import Foundation

indirect enum CBOR {
    case uint(UInt64)
    case nint(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case tag(UInt64, CBOR)
    case other
}

struct CBORReader {
    enum Failure: Error { case invalid }
    let bytes: [UInt8]
    var cursor = 0
    var isAtEnd: Bool { cursor == bytes.count }
    var remaining: Int { bytes.count - cursor }

    mutating func next() throws -> UInt8 {
        guard cursor < bytes.count else { throw Failure.invalid }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    mutating func read(depth: Int = 0) throws -> CBOR {
        guard depth <= 16 else { throw Failure.invalid }
        let head = try next()
        let major = head >> 5
        let info = head & 31
        let count: UInt64
        switch info {
        case 0...23: count = UInt64(info)
        case 24...27:
            var number: UInt64 = 0
            for _ in 0..<(1 << Int(info - 24)) { number = (number << 8) | UInt64(try next()) }
            count = number
        default: throw Failure.invalid // Indefinite/reserved forms are not this token profile.
        }
        switch major {
        case 0: return .uint(count)
        case 1: return .nint(count)
        case 7: return .other
        case 2, 3:
            guard count <= UInt64(remaining) else { throw Failure.invalid }
            let end = cursor + Int(count)
            let data = Array(bytes[cursor..<end])
            cursor = end
            if major == 2 { return .bytes(data) }
            // Foundation drops a leading U+FEFF; a text that does not read back as its own bytes fails closed.
            guard let text = String(bytes: data, encoding: .utf8), text.utf8.elementsEqual(data) else {
                throw Failure.invalid
            }
            return .text(text)
        case 4:
            guard count <= UInt64(remaining) else { throw Failure.invalid }
            var items: [CBOR] = []
            for _ in 0..<Int(count) { items.append(try read(depth: depth + 1)) }
            return .array(items)
        case 5:
            guard count <= UInt64(remaining / 2) else { throw Failure.invalid }
            var pairs: [(CBOR, CBOR)] = []
            for _ in 0..<Int(count) {
                pairs.append((try read(depth: depth + 1), try read(depth: depth + 1)))
            }
            return .map(pairs)
        case 6: return .tag(count, try read(depth: depth + 1))
        default: throw Failure.invalid
        }
    }
}
