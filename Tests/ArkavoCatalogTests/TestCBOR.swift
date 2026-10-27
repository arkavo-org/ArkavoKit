import Foundation

/// A test-only definite-length CBOR encoder with shortest-form heads. `.nint(n)` is −1−n, as major type 1 carries it; `.raw`
/// splices bytes exactly as given. Its output for the golden attestation's header and claims is authnz-rs's encoding.
indirect enum TestCBOR: Sendable {
    case uint(UInt64), nint(UInt64), text(String), bytes([UInt8]), array([TestCBOR]), map([(TestCBOR, TestCBOR)])
    case tag(UInt64, TestCBOR)
    case raw([UInt8])

    var encoded: [UInt8] {
        func head(_ major: UInt8, _ n: UInt64) -> [UInt8] {
            switch n {
            case 0..<24: return [major << 5 | UInt8(n)]
            case 24..<256: return [major << 5 | 24, UInt8(n)]
            case 256..<65_536: return [major << 5 | 25, UInt8(n >> 8), UInt8(n & 0xff)]
            case 65_536...0xFFFF_FFFF:
                return [major << 5 | 26] + stride(from: 24, through: 0, by: -8).map { UInt8(truncatingIfNeeded: n >> $0) }
            default: return [major << 5 | 27] + stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: n >> $0) }
            }
        }
        switch self {
        case .uint(let n): return head(0, n)
        case .nint(let n): return head(1, n)
        case .bytes(let b): return head(2, UInt64(b.count)) + b
        case .text(let s): let b = Array(s.utf8); return head(3, UInt64(b.count)) + b
        case .array(let a): return head(4, UInt64(a.count)) + a.flatMap(\.encoded)
        case .map(let m): return head(5, UInt64(m.count)) + m.flatMap { $0.0.encoded + $0.1.encoded }
        case .tag(let n, let item): return head(6, n) + item.encoded
        case .raw(let b): return b
        }
    }

    /// The encoding as `Data`.
    var data: Data { Data(encoded) }
}
